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

  @observability ~w(effect.settled autopoet.attention recall.ab reward.landed app.executed)

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
  validate-the-instrument). The chamber-validated rule verbatim: `w += η*(1-w)`
  on an observed transition, lazy multiplicative decay at read. The state map is
  the GenServer's state verbatim (`g/prev/t/n`) — snapshots stay compatible.

  PINNED production config: η=0.35, decay=0.9985 (chamber spike 1). `new/1`
  accepts a cfg override — for the Select tournament (wb-phbt5) ONLY: variants
  compete in replay; the live learner always runs the pinned defaults, and a
  constant change is a human act (pre-registration discipline, never mid-run).
  """

  @default_cfg %{eta: 0.35, decay: 0.9985}
  @hop2_damp 0.5

  def new(cfg \\ %{}),
    do: %{g: %{}, prev: nil, t: 0, n: 0, cfg: Map.merge(@default_cfg, Map.new(cfg))}

  @doc "Observe one workload signal (the live learner's per-event step)."
  def observe(m, sig) do
    g = if m.prev, do: bump(m.g, m.prev, sig, m.t, cfg(m)), else: m.g
    %{m | g: g, prev: sig, t: m.t + 1, n: m.n + 1}
  end

  @doc "Observe an explicit src→dst transition (composite-context experiments — e.g. an order-2 model keying edges on bigram contexts). Same arithmetic, caller supplies the source."
  def observe_edge(m, src, dst) do
    %{m | g: bump(m.g, src, dst, m.t, cfg(m)), t: m.t + 1, n: m.n + 1}
  end

  @doc """
  Seed PRIOR edges (template genome, chamber cold-start correction): Dirichlet-
  style pseudo-counts with deliberately small mass — a wrong prior is
  structurally cheap (live traffic washes it out in minutes; the decay sheds the
  rest). Never frozen weights; `mass` defaults to the weight ~3 co-activations
  would earn. Idempotent-ish: seeding never lowers an existing edge.

  `edges` may be `{src, dst}` (default mass) or `{src, dst, mass}` (per-edge —
  the embedding nominator seeds by similarity, the fleet prior by aggregated
  count).
  """
  def seed(m, edges, mass \\ 0.7) do
    g =
      Enum.reduce(edges, m.g, fn edge, g ->
        {src, dst, w} =
          case edge do
            {s, d, w} -> {to_string(s), to_string(d), w}
            {s, d} -> {to_string(s), to_string(d), mass}
          end

        row = Map.get(g, src, %{})
        {w0, tl} = Map.get(row, dst, {0.0, m.t})
        Map.put(g, src, Map.put(row, dst, {max(w0, w), tl}))
      end)

    %{m | g: g}
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
    d = cfg(m).decay

    for {b, {w, tl}} <- Map.get(m.g, node, %{}) do
      {b, w * :math.pow(d, m.t - tl)}
    end
  end

  @doc """
  Prune edges whose DECAYED weight has fallen below `eps` (wb-5ih92): a
  long-lived install's graph is bounded by its ACTIVE vocabulary, not its
  lifetime event count. Empty source rows are dropped. Pure; call at snapshot.
  """
  def prune(m, eps \\ 0.02) do
    g =
      m.g
      |> Enum.map(fn {src, row} ->
        kept =
          for {dst, {w, tl}} <- row, w * :math.pow(cfg(m).decay, m.t - tl) >= eps, into: %{} do
            {dst, {w, tl}}
          end

        {src, kept}
      end)
      |> Enum.reject(fn {_src, row} -> row == %{} end)
      |> Map.new()

    %{m | g: g}
  end

  @doc "The PINNED production decay (stats display + fair baselines)."
  def decay, do: @default_cfg.decay

  def default_cfg, do: @default_cfg

  # tolerate raw state maps (old snapshots restored without :cfg)
  defp cfg(m), do: Map.get(m, :cfg) || @default_cfg

  defp bump(g, a, b, t, cfg) do
    edges = Map.get(g, a, %{})
    {w0, tl} = Map.get(edges, b, {0.0, t})
    w = w0 * :math.pow(cfg.decay, t - tl)
    Map.put(g, a, Map.put(edges, b, {w + cfg.eta * (1.0 - w), t}))
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

  @doc "Seed genome prior edges into the live learner (intake boot-time; small pseudo-count mass)."
  def seed_prior(edges), do: GenServer.call(__MODULE__, {:seed_prior, edges})

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

  def handle_call({:seed_prior, edges}, _from, s) do
    s = Model.seed(s, edges)
    Autopoet.Log.puts("shadow: genome prior seeded — #{length(edges)} edge(s), small mass")
    {:reply, :ok, s}
  end

  @impl true
  def terminate(_reason, s), do: persist(s)

  # D2 provenance header rides every snapshot: which arithmetic + prior produced
  # this state (schema versioned so future migrations know what they're reading).
  # Prune at snapshot (wb-5ih92) so a long-lived install's graph stays bounded by
  # active vocabulary, not lifetime events.
  defp persist(s) do
    pruned = Model.prune(s)

    Autopoet.Shadow.save(
      "hebb",
      pruned
      |> Map.take([:g, :prev, :t, :n])
      |> Map.put(:meta, %{schema: 1, cfg: Model.default_cfg(), prior: "plan-derived-v1"})
    )
  end
end

defmodule Autopoet.Shadow.Surprise.Model do
  @moduledoc """
  The PURE surprise predictor + PINNED drift detector arithmetic (chamber E3,
  replay-corrected) — factored out so the detector-benchmark eval measures the
  REAL detector, never a reimplementation. `observe/3` returns `{state, alarm?}`;
  the GenServer owns bus/log/emit, the eval drives streams directly.
  """

  @decay 0.995
  @alpha 0.5
  @vocab_hint 40
  @a_fast 0.02
  @a_slow 0.002
  @ratio 1.10
  @floor 1.0

  def new, do: %{model: %{}, prev: :none, t: 0, n: 0, f: nil, s: nil, run: 0, alarms: 0}

  @doc "Observe one signal with the pinned constants; `{state', alarm_fired?}`."
  def observe(st, sig, sustain \\ 15) do
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

    if run == sustain,
      do: {%{st | alarms: st.alarms + 1, run: 0}, true},
      else: {st, false}
  end
end

defmodule Autopoet.Shadow.Surprise do
  @moduledoc """
  Live surprise predictor + the PINNED drift detector (chamber E3, replay-corrected):
  EMA fast(0.02)/slow(0.002) ratio > 1.10 sustained 15 events AND fast > 1.0 bit —
  drift must be relative AND material. On alarm: a log line + an
  `autopoet.attention` event (broadcast-recorded by capture; excluded from learning).
  All arithmetic lives in `Surprise.Model` (pure — shared verbatim with the
  detector-benchmark eval).

  `:drift_sustain` app env overrides the sustain in tests ONLY — production runs the
  pinned constant.

  State survives reboots via `Autopoet.Shadow.save/load` (snapshot `surprise.etf`).
  """
  use GenServer

  alias Autopoet.Shadow.Surprise.Model

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

    state =
      case Autopoet.Shadow.load("surprise") do
        {:ok, saved} -> Map.merge(Model.new(), saved)
        :none -> Model.new()
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:event, ev}, st) do
    if Autopoet.Shadow.workload?(ev) do
      case Model.observe(st, Autopoet.Shadow.signal(ev), sustain()) do
        {st, true} ->
          Autopoet.Log.puts(
            "ATTENTION: workload drift — surprise fast #{Float.round(st.f, 2)} vs slow #{Float.round(st.s, 2)} bits (alarm ##{st.alarms})"
          )

          Nexus.Events.emit(%{
            kind: "autopoet.attention",
            reason: "drift",
            fast: st.f,
            slow: st.s,
            tags: []
          })

          {:noreply, st}

        {st, false} ->
          {:noreply, st}
      end
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
end

defmodule Autopoet.Shadow.Outcomes.Model do
  @moduledoc """
  The PURE outcome-ledger fold — the exact counting the live ledger runs,
  factored out so integrity sweeps replay a trace through the REAL arithmetic
  (conservation: replaying a capture must reproduce the live ledger).
  State map is the GenServer's state verbatim (`effects/proposals/n`).
  """

  @proposal_kinds ~w(proposal.recorded proposal.accepted proposal.rejected proposal.reverted)

  def new, do: %{effects: %{}, proposals: %{}, rewards: %{}, n: 0}

  def proposal_kinds, do: @proposal_kinds

  @doc "Fold ONE event into the ledger (identity for non-feedback events)."
  def reduce(s, %{kind: "effect.settled"} = ev) do
    key = {to_string(ev[:hook]), to_string(ev[:effect])}

    cell =
      Map.get(s.effects, key, %{ok: 0, error: 0, us: 0})
      |> Map.update!(if(ev[:status] == :ok, do: :ok, else: :error), &(&1 + 1))
      |> Map.update!(:us, &(&1 + (ev[:duration_us] || 0)))

    %{s | effects: Map.put(s.effects, key, cell), n: s.n + 1}
  end

  def reduce(s, %{kind: kind} = ev) when kind in @proposal_kinds do
    verdict = kind |> String.split(".") |> List.last() |> String.to_atom()
    target = to_string(ev[:target] || ev[:proposal] || "?")

    cell =
      Map.get(s.proposals, target, %{recorded: 0, accepted: 0, rejected: 0, reverted: 0})
      |> Map.update!(verdict, &(&1 + 1))

    %{s | proposals: Map.put(s.proposals, target, cell), n: s.n + 1}
  end

  # E3: an external reward (billing/usage) credited to a locus — the money
  # boundary the credit layer (phase 3) will pay along.
  def reduce(s, %{kind: "reward.landed"} = ev) do
    target = to_string(ev[:target] || "?")
    rewards = Map.get(s, :rewards, %{})

    cell =
      Map.get(rewards, target, %{count: 0, amount: 0.0})
      |> Map.update!(:count, &(&1 + 1))
      |> Map.update!(:amount, &(&1 + (ev[:amount] || 0.0)))

    %{s | rewards: Map.put(rewards, target, cell), n: s.n + 1}
  end

  def reduce(s, _ev), do: s
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

  All counting lives in `Outcomes.Model` (pure — shared verbatim with the
  integrity sweeps). Read via `stats/0` (dashboard, evals) or `ledger/0` (full
  detail). State is durable (`outcomes.etf`) like every learner. Pure observer:
  consumes feedback, emits nothing, mutates nothing.
  """
  use GenServer

  alias Autopoet.Shadow.Outcomes.Model

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

    state =
      case Autopoet.Shadow.load("outcomes") do
        {:ok, saved} -> Map.merge(Model.new(), saved)
        :none -> Model.new()
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:event, ev}, s), do: {:noreply, Model.reduce(s, ev)}

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

    rewards = Map.get(s, :rewards, %{})

    reward_total =
      rewards |> Map.values() |> Enum.reduce(%{count: 0, amount: 0.0}, fn c, a ->
        %{count: a.count + c.count, amount: a.amount + c.amount}
      end)

    {:reply,
     %{observed: s.n, effects: map_size(s.effects), settled: settled, proposals: verdicts, rewards: reward_total},
     s}
  end

  def handle_call(:ledger, _from, s), do: {:reply, Map.take(s, [:effects, :proposals, :rewards, :n]), s}

  def handle_call(:snapshot, _from, s), do: {:reply, persist(s), s}

  @impl true
  def terminate(_reason, s), do: persist(s)

  defp persist(s), do: Autopoet.Shadow.save("outcomes", Map.take(s, [:effects, :proposals, :rewards, :n]))
end
