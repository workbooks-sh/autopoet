defmodule Autopoet.Shadow.Companion do
  @moduledoc """
  The BEAM-native shadow COMPANION — the one entry point that runs the nexus's
  learned analysis over the captured behavioral corpus, wiring together the three
  Nx-native lenses so none is dead code:

    * `Autopoet.Shadow.Trace.order_gate/2` — the k-order Markov baseline: is there
      higher-order structure a first-order detector misses?
    * `Autopoet.Shadow.Profile.cluster/2` — Scholar/GMM TABULAR clustering: which
      loci are deterministic-spine vs branch/decision (learned bands, not thresholds)?
    * `Autopoet.Shadow.Sequence.analyze/2` — the self-training minGRU SEQUENCE model:
      does a learned recurrent predictor beat the Markov baseline on held-out entropy?

  Nexus-native: pure `Nx` + `Scholar` (no Python, no mic/speaker, no weight files),
  so the SAME companion runs on the local desktop nexus AND the workbooks.sh cloud
  nexus. It reads the corpus `Autopoet.Capture` already writes; it never captures or
  mutates anything. Exposed at `GET /shadow/companion` (see `home/routes.work`).
  """
  alias Autopoet.Shadow.{Trace, Profile, Sequence}

  @doc """
  Run all three lenses over the captured corpus and return one JSON-safe report.
  `:level` picks the signal granularity (`:kind` ~25 types — dense fast; `:doc` per
  document — high-cardinality). Options pass through to the models (`:k`, `:max_steps`).
  """
  def analyze(opts \\ []) do
    level = Keyword.get(opts, :level, :kind)
    signals = Trace.dir() |> Trace.events() |> Trace.signals(level)

    stats = Trace.stats(signals)

    %{
      corpus: %{stats | top: Enum.map(stats.top, fn {sig, c} -> [to_string(sig), c] end)},
      order_gate: jsonable(Trace.order_gate(signals, opts)),
      tabular: tabular(signals, opts),
      sequence: Sequence.analyze(signals, opts)
    }
  end

  # Scholar clustering → a compact, JSON-safe band summary (or the honest skip reason).
  defp tabular(signals, opts) do
    case Profile.cluster(signals, opts) do
      :insufficient_loci ->
        %{status: "insufficient_loci"}

      %{loci: loci, types: types} ->
        %{
          status: "ok",
          types: Map.new(types, fn {cid, label} -> {to_string(cid), label} end),
          bands: Enum.frequencies_by(loci, & &1.type),
          loci: Enum.map(loci, fn r -> %{r | locus: to_string(r.locus)} end)
        }
    end
  end

  # order_gate returns atom keys + a :verdict atom — make it JSON-safe.
  defp jsonable(gate) do
    Map.new(gate, fn
      {:verdict, v} -> {"verdict", to_string(v)}
      {:meta, m} -> {"meta", m}
      {k, %{} = row} -> {to_string(k), row}
      {k, v} -> {to_string(k), v}
    end)
  end
end
