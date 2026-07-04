defmodule Autopoet.Shadow do
  @moduledoc """
  Shared shadow-layer plumbing. The shadow layer OBSERVES the real bus and never
  acts — v2 of the containment ladder. (The ONE sanctioned actuator is the
  weighted recall readout `Autopoet.Shadow.Hebb.recall/2` — ranking only, worst
  case is slightly worse ordering; nothing mutates, nothing merges.)

  Two event classes: WORKLOAD (learnable) vs OBSERVABILITY (feedback the shadow
  layer itself produces or consumes — `effect.settled`, `autopoet.attention`).
  Learning on observability events would close a feedback loop on ourselves.

  The learned signal per event: the most specific locus available —
  `doc` field, else `target`, else the event kind.

  Learner state is DURABLE (Autopoiesis v3 phase 0 — nothing is lost): one atomic
  ETF snapshot per learner at `data/shadow/<name>.etf`, saved on a timer and at
  terminate, restored at init. A missing/corrupt snapshot means a cold learner,
  never a crash.
  """

  @observability ~w(effect.settled autopoet.attention)

  def workload?(ev), do: to_string(ev[:kind]) not in @observability

  def signal(ev), do: to_string(ev[:doc] || ev[:target] || ev[:kind])

  # ── learner-state persistence ────────────────────────────────────────────────

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "shadow"])

  def save(name, term) do
    File.mkdir_p!(dir())
    path = Path.join(dir(), "#{name}.etf")
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(term)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ -> File.rm(tmp)
    end
  end

  def load(name) do
    case File.read(Path.join(dir(), "#{name}.etf")) do
      {:ok, bin} ->
        try do
          {:ok, :erlang.binary_to_term(bin)}
        rescue
          _ -> :none
        end

      _ ->
        :none
    end
  end

  @save_ms 60_000
  def schedule_save, do: Process.send_after(self(), :shadow_save, @save_ms)
end

defmodule Autopoet.Shadow.Hebb.Model do
  @moduledoc """
  The PURE Hebbian model — the exact arithmetic the live learner runs, factored
  out so the replay/eval harness scores the REAL model (never a reimplementation;
  validate-the-instrument). The chamber-validated rule verbatim: `w += 0.35*(1-w)`
  on an observed transition, lazy multiplicative decay at read. The state map is
  the GenServer's state verbatim (`g/prev/t/n`) — snapshots stay compatible.
  """

  @eta 0.35
  @decay 0.9985
  @hop2_damp 0.5

  def new, do: %{g: %{}, prev: nil, t: 0, n: 0}

  @doc "Observe one workload signal (the live learner's per-event step)."
  def observe(m, sig) do
    g = if m.prev, do: bump(m.g, m.prev, sig, m.t), else: m.g
    %{m | g: g, prev: sig, t: m.t + 1, n: m.n + 1}
  end

  @doc "Predict the next locus after `from`: 1-hop successors by decayed weight, best-first."
  def predict(m, from, k) do
    m
    |> decayed_edges(from)
    |> Enum.sort_by(fn {_, w} -> -w end)
    |> Enum.take(k)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Weighted spreading activation from `locus`: 1-hop at edge weight, 2-hop damped, summed over paths."
  def recall(m, locus, k) do
    hop1 = decayed_edges(m, locus)

    Enum.reduce(hop1, %{}, fn {b, w1}, acc ->
      acc = Map.update(acc, b, w1, &(&1 + w1))

      Enum.reduce(decayed_edges(m, b), acc, fn {c, w2}, acc2 ->
        if c == locus,
          do: acc2,
          else: Map.update(acc2, c, w1 * w2 * @hop2_damp, &(&1 + w1 * w2 * @hop2_damp))
      end)
    end)
    |> Enum.sort_by(fn {_, a} -> -a end)
    |> Enum.take(k)
  end

  def decayed_edges(m, node) do
    for {b, {w, tl}} <- Map.get(m.g, node, %{}) do
      {b, w * :math.pow(@decay, m.t - tl)}
    end
  end

  def decay, do: @decay

  defp bump(g, a, b, t) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = w0 * :math.pow(@decay, t - tl)
    Map.put(g, a, Map.put(edges, b, {w + @eta * (1.0 - w), t}))
  end
end

defmodule Autopoet.Shadow.Hebb do
  @moduledoc """
  Live Hebbian pathway learner over the real bus (shadow — zero mutation).
  All arithmetic lives in `Autopoet.Shadow.Hebb.Model` (pure — shared verbatim
  with the replay/eval harness); this GenServer is the bus subscription, the
  durable snapshot, and the query surface.

  `recall/2` is the FIRST ACTUATOR (wb-mdk4.6, ladder rung 4): weighted spreading
  activation over the learned graph — ranking only, consumers may reorder what
  they already show, nothing else.

  State survives reboots via `Autopoet.Shadow.save/load` (snapshot `hebb.etf`).
  """
  use GenServer

  alias Autopoet.Shadow.Hebb.Model

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Force a synchronous state snapshot to disk (shutdown path + tests)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Weighted spreading-activation readout from `locus` — the actuator surface. `[{locus, activation}]` best-first."
  def recall(locus, k \\ 5), do: GenServer.call(__MODULE__, {:recall, to_string(locus), k})

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Nexus.Events.subscribe()
    Autopoet.Shadow.schedule_save()

    state =
      case Autopoet.Shadow.load("hebb") do
        {:ok, saved} -> Map.merge(Model.new(), saved)
        :none -> Model.new()
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:event, ev}, s) do
    if Autopoet.Shadow.workload?(ev) do
      {:noreply, Model.observe(s, Autopoet.Shadow.signal(ev))}
    else
      {:noreply, s}
    end
  end

  def handle_info(:shadow_save, s) do
    persist(s)
    Autopoet.Shadow.schedule_save()
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_call(:stats, _from, s) do
    weights =
      for {a, es} <- s.g, {b, {w, tl}} <- es do
        {a, b, w * :math.pow(Model.decay(), s.t - tl)}
      end

    {:reply,
     %{
       events: s.n,
       nodes: map_size(s.g),
       edges: length(weights),
       top: weights |> Enum.sort_by(fn {_, _, w} -> -w end) |> Enum.take(3)
     }, s}
  end

  def handle_call(:snapshot, _from, s) do
    {:reply, persist(s), s}
  end

  def handle_call({:recall, locus, k}, _from, s) do
    {:reply, Model.recall(s, locus, k), s}
  end

  @impl true
  def terminate(_reason, s), do: persist(s)

  defp persist(s), do: Autopoet.Shadow.save("hebb", Map.take(s, [:g, :prev, :t, :n]))
end

defmodule Autopoet.Shadow.Surprise do
  @moduledoc """
  Live surprise predictor + the PINNED drift detector (chamber E3, replay-corrected):
  EMA fast(0.02)/slow(0.002) ratio > 1.10 sustained 15 events AND fast > 1.0 bit —
  drift must be relative AND material. On alarm: a log line + an
  `autopoet.attention` event (broadcast-recorded by capture; excluded from learning).

  `:drift_sustain` app env overrides the sustain in tests ONLY — production runs the
  pinned constant.

  State survives reboots via `Autopoet.Shadow.save/load` (snapshot `surprise.etf`).
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

  @doc "Force a synchronous state snapshot to disk (shutdown path + tests)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  defp sustain, do: Application.get_env(:autopoet, :drift_sustain, 15)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Nexus.Events.subscribe()
    Autopoet.Shadow.schedule_save()

    base = %{model: %{}, prev: :none, t: 0, n: 0, f: nil, s: nil, run: 0, alarms: 0}

    state =
      case Autopoet.Shadow.load("surprise") do
        {:ok, saved} -> Map.merge(base, saved)
        :none -> base
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:event, ev}, st) do
    if Autopoet.Shadow.workload?(ev) do
      {:noreply, observe(st, Autopoet.Shadow.signal(ev))}
    else
      {:noreply, st}
    end
  end

  def handle_info(:shadow_save, st) do
    persist(st)
    Autopoet.Shadow.schedule_save()
    {:noreply, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def handle_call(:stats, _from, st) do
    {:reply, %{events: st.n, fast: st.f, slow: st.s, alarms: st.alarms}, st}
  end

  def handle_call(:snapshot, _from, st) do
    {:reply, persist(st), st}
  end

  @impl true
  def terminate(_reason, st), do: persist(st)

  defp persist(st), do: Autopoet.Shadow.save("surprise", st)

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

defmodule Autopoet.Shadow.Outcomes do
  @moduledoc """
  The outcome/reward ledger — the feedback half of the loop (Autopoiesis v3
  phase 0). Where Hebb/Surprise learn from the WORKLOAD stream, this module
  consumes the FEEDBACK stream and keeps machine-readable per-locus outcomes:

    * `effect.settled` — per {hook, effect}: ok/error counts + total duration.
      The per-pathway signal the credit layer (phase 3) will pay along.
    * `proposal.recorded|accepted|rejected|reverted` — the human reward stream
      (accept/reject IS the first labeled reward signal), per proposal target.

  Read it via `stats/0` (dashboard, evals) or `ledger/0` (full detail). State is
  durable (`outcomes.etf`) like every learner: reward history survives reboots.
  Pure observer: consumes feedback, emits nothing, mutates nothing.
  """
  use GenServer

  @proposal_kinds ~w(proposal.recorded proposal.accepted proposal.rejected proposal.reverted)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)
  def ledger, do: GenServer.call(__MODULE__, :ledger)

  @doc "Force a synchronous state snapshot to disk (shutdown path + tests)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Nexus.Events.subscribe()
    Autopoet.Shadow.schedule_save()

    base = %{effects: %{}, proposals: %{}, n: 0}

    state =
      case Autopoet.Shadow.load("outcomes") do
        {:ok, saved} -> Map.merge(base, saved)
        :none -> base
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:event, %{kind: "effect.settled"} = ev}, s) do
    key = {to_string(ev[:hook]), to_string(ev[:effect])}

    cell =
      Map.get(s.effects, key, %{ok: 0, error: 0, us: 0})
      |> Map.update!(if(ev[:status] == :ok, do: :ok, else: :error), &(&1 + 1))
      |> Map.update!(:us, &(&1 + (ev[:duration_us] || 0)))

    {:noreply, %{s | effects: Map.put(s.effects, key, cell), n: s.n + 1}}
  end

  def handle_info({:event, %{kind: kind} = ev}, s) when kind in @proposal_kinds do
    verdict = kind |> String.split(".") |> List.last() |> String.to_atom()
    target = to_string(ev[:target] || ev[:proposal] || "?")

    cell =
      Map.get(s.proposals, target, %{recorded: 0, accepted: 0, rejected: 0, reverted: 0})
      |> Map.update!(verdict, &(&1 + 1))

    {:noreply, %{s | proposals: Map.put(s.proposals, target, cell), n: s.n + 1}}
  end

  def handle_info({:event, _ev}, s), do: {:noreply, s}

  def handle_info(:shadow_save, s) do
    persist(s)
    Autopoet.Shadow.schedule_save()
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_call(:stats, _from, s) do
    settled = s.effects |> Map.values() |> Enum.reduce(%{ok: 0, error: 0}, fn c, a ->
      %{ok: a.ok + c.ok, error: a.error + c.error}
    end)

    verdicts = s.proposals |> Map.values() |> Enum.reduce(%{recorded: 0, accepted: 0, rejected: 0, reverted: 0}, fn c, a ->
      %{recorded: a.recorded + c.recorded, accepted: a.accepted + c.accepted,
        rejected: a.rejected + c.rejected, reverted: a.reverted + c.reverted}
    end)

    {:reply, %{observed: s.n, effects: map_size(s.effects), settled: settled, proposals: verdicts}, s}
  end

  def handle_call(:ledger, _from, s), do: {:reply, Map.take(s, [:effects, :proposals, :n]), s}

  def handle_call(:snapshot, _from, s), do: {:reply, persist(s), s}

  @impl true
  def terminate(_reason, s), do: persist(s)

  defp persist(s), do: Autopoet.Shadow.save("outcomes", Map.take(s, [:effects, :proposals, :n]))
end
