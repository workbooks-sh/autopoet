defmodule Autopoet.Shadow do
  @moduledoc """
  Shared shadow-layer plumbing. The shadow layer OBSERVES the real bus and never
  acts — v2 of the containment ladder.

  Two event classes: WORKLOAD (learnable) vs OBSERVABILITY (feedback the shadow
  layer itself produces or consumes — `effect.settled`, `autopoet.attention`).
  Learning on observability events would close a feedback loop on ourselves.

  The learned signal per event: the most specific locus available —
  `doc` field, else `target`, else the event kind.
  """

  @observability ~w(effect.settled autopoet.attention)

  def workload?(ev), do: to_string(ev[:kind]) not in @observability

  def signal(ev), do: to_string(ev[:doc] || ev[:target] || ev[:kind])
end

defmodule Autopoet.Shadow.Hebb do
  @moduledoc """
  Live Hebbian pathway learner over the real bus (shadow — zero actuators).
  The chamber-validated rule verbatim: `w += 0.35*(1-w)` on an observed transition,
  lazy multiplicative decay at read. Decay is a per-stream tunable (ASSUMPTIONS.md
  A1: cumulative counts beat decay on slow-drift streams — revisit when real usage
  accumulates).
  """
  use GenServer

  @eta 0.35
  @decay 0.9985

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(nil) do
    Nexus.Events.subscribe()
    {:ok, %{g: %{}, prev: nil, t: 0, n: 0}}
  end

  @impl true
  def handle_info({:event, ev}, s) do
    if Autopoet.Shadow.workload?(ev) do
      sig = Autopoet.Shadow.signal(ev)
      g = if s.prev, do: bump(s.g, s.prev, sig, s.t), else: s.g
      {:noreply, %{s | g: g, prev: sig, t: s.t + 1, n: s.n + 1}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_call(:stats, _from, s) do
    weights =
      for {a, es} <- s.g, {b, {w, tl}} <- es do
        {a, b, w * :math.pow(@decay, s.t - tl)}
      end

    {:reply,
     %{
       events: s.n,
       nodes: map_size(s.g),
       edges: length(weights),
       top: weights |> Enum.sort_by(fn {_, _, w} -> -w end) |> Enum.take(3)
     }, s}
  end

  defp bump(g, a, b, t) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = w0 * :math.pow(@decay, t - tl)
    Map.put(g, a, Map.put(edges, b, {w + @eta * (1.0 - w), t}))
  end
end

defmodule Autopoet.Shadow.Surprise do
  @moduledoc """
  Live surprise predictor + the PINNED drift detector (chamber E3, replay-corrected):
  EMA fast(0.02)/slow(0.002) ratio > 1.10 sustained 15 events AND fast > 1.0 bit —
  drift must be relative AND material. On alarm: a log line + an
  `autopoet.attention` event (broadcast-recorded by capture; excluded from learning).

  `:drift_sustain` app env overrides the sustain in tests ONLY — production runs the
  pinned constant.
  """
  use GenServer

  @decay 0.995
  @alpha 0.5
  @vocab_hint 40
  @a_fast 0.02
  @a_slow 0.002
  @ratio 1.10
  @floor 1.0

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  defp sustain, do: Application.get_env(:autopoet, :drift_sustain, 15)

  @impl true
  def init(nil) do
    Nexus.Events.subscribe()
    {:ok, %{model: %{}, prev: :none, t: 0, n: 0, f: nil, s: nil, run: 0, alarms: 0}}
  end

  @impl true
  def handle_info({:event, ev}, st) do
    if Autopoet.Shadow.workload?(ev) do
      {:noreply, observe(st, Autopoet.Shadow.signal(ev))}
    else
      {:noreply, st}
    end
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def handle_call(:stats, _from, st) do
    {:reply, %{events: st.n, fast: st.f, slow: st.s, alarms: st.alarms}, st}
  end

  defp observe(st, sig) do
    {counts, total, tl} = Map.get(st.model, st.prev, {%{}, 0.0, st.t})
    d = :math.pow(@decay, st.t - tl)
    p = (Map.get(counts, sig, 0.0) * d + @alpha) / (total * d + @alpha * @vocab_hint)
    x = -:math.log2(p)

    counts = Map.new(counts, fn {k, c} -> {k, c * d} end) |> Map.update(sig, 1.0, &(&1 + 1.0))
    model = Map.put(st.model, st.prev, {counts, total * d + 1.0, st.t})

    f = if st.f, do: st.f + @a_fast * (x - st.f), else: x
    s = if st.s, do: st.s + @a_slow * (x - st.s), else: x
    run = if f > @ratio * s and f > @floor, do: st.run + 1, else: 0

    st = %{st | model: model, prev: sig, t: st.t + 1, n: st.n + 1, f: f, s: s, run: run}

    if run == sustain() do
      Autopoet.Log.puts(
        "ATTENTION: workload drift — surprise fast #{Float.round(f, 2)} vs slow #{Float.round(s, 2)} bits (alarm ##{st.alarms + 1})"
      )

      Nexus.Events.emit(%{
        kind: "autopoet.attention",
        reason: "drift",
        fast: f,
        slow: s,
        tags: []
      })

      %{st | alarms: st.alarms + 1, run: 0}
    else
      st
    end
  end
end
