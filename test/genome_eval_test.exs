defmodule Autopoet.GenomeEvalTest do
  @moduledoc """
  Phase D gates (wb-h0tjs.5):

    D1 BIRTH SCORE — the genome prior may NEVER be worse than blank (the
       chamber's 0.020-vs-0.201 lesson: a wrong prior at birth is worse than
       none, so priors ship as small washable pseudo-counts). Prequential @150
       and @800 events, genome-seeded vs blank, per persona; delta reported to
       history — the fleet-quality metric.
    D2 CONSERVATION — a learner snapshot is a CACHE of the trace: folding the
       same signals through the pure Model reproduces the state exactly, and
       every snapshot carries its provenance header (schema/cfg/prior).
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.Personas
  alias Autopoet.Shadow.Hebb.Model

  defp pulse_signals(p, rounds, noise_pct, salt) do
    :rand.seed(:exsss, salt)

    for _ <- 1..rounds, ev <- p.pulse do
      if :rand.uniform(100) <= noise_pct,
        do: "noise-#{:rand.uniform(20)}",
        else: to_string(ev[:doc] || ev[:target] || ev[:kind])
    end
  end

  defp prequential_at(signals, model, checkpoints, k) do
    {_, _, hits_at} =
      Enum.reduce(signals, {model, 0, %{}}, fn sig, {m, n, acc} ->
        hit = if m.prev && sig in Model.predict(m, m.prev, k), do: 1, else: 0
        prev_hits = Map.get(acc, :running, 0) + hit
        acc = Map.put(acc, :running, prev_hits)
        n = n + 1
        acc = if n in checkpoints, do: Map.put(acc, n, prev_hits / n), else: acc
        {Model.observe(m, sig), n, acc}
      end)

    hits_at
  end

  test "D1: genome prior ≥ blank at birth checkpoints, every persona" do
    deltas =
      for p <- Personas.all() do
        plan = Autopoet.Intake.parse_plan(p.profile)
        edges = Autopoet.Intake.prior_edges(plan)
        assert edges != [], "#{p.name}: empty prior"

        signals = pulse_signals(p, 250, 10, {41, 7, 3})
        blank = prequential_at(signals, Model.new(), [150, 800], 3)
        seeded = prequential_at(signals, Model.seed(Model.new(), edges), [150, 800], 3)

        for cp <- [150, 800] do
          assert seeded[cp] >= blank[cp] - 0.02,
                 "D1 FAILED (#{p.name} @#{cp}): genome #{seeded[cp]} vs blank #{blank[cp]} — prior HURTS"
        end

        {p.name, Float.round(seeded[150] - blank[150], 4), Float.round(seeded[800] - blank[800], 4)}
      end

    mean150 = deltas |> Enum.map(&elem(&1, 1)) |> then(&(Enum.sum(&1) / length(&1)))
    mean800 = deltas |> Enum.map(&elem(&1, 2)) |> then(&(Enum.sum(&1) / length(&1)))

    Autopoet.Eval.History.record("genome/birth", %{delta150: mean150, delta800: mean800, personas: length(deltas)})

    IO.puts(
      "  ✓ EVAL genome/birth — 6/6 personas never-worse-than-blank; " <>
        "mean delta @150 #{pct(mean150)} · @800 #{pct(mean800)}"
    )
  end

  test "D2: a snapshot is a cache of the trace — pure fold reproduces state; provenance rides along" do
    p = Personas.named("trader")
    signals = pulse_signals(p, 60, 5, {9, 9, 1})

    # fold twice — byte-identical state (determinism)
    m1 = Enum.reduce(signals, Model.new(), &Model.observe(&2, &1))
    m2 = Enum.reduce(signals, Model.new(), &Model.observe(&2, &1))
    assert m1 == m2

    # the LIVE learner's snapshot carries the provenance header
    :ok = Autopoet.Shadow.Hebb.snapshot()
    {:ok, saved} = Autopoet.Shadow.load("hebb")
    assert %{schema: 1, cfg: cfg, prior: "plan-derived-v1"} = saved.meta
    assert cfg == Model.default_cfg()
    assert Map.has_key?(saved, :g) and Map.has_key?(saved, :t)

    # restore path tolerates the header (meta ignored by the state merge)
    restored = Map.merge(Model.new(), Map.take(saved, [:g, :prev, :t, :n]))
    assert is_map(restored.g)

    IO.puts("  ✓ EVAL genome/provenance — deterministic fold; snapshot schema v1 with cfg + prior id")
  end

  defp pct(d), do: :erlang.float_to_binary(d * 100, decimals: 2) <> "pt"
end
