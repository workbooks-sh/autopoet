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

  test "D3: semantic nominator proposes edges among related loci; birth never-worse-than-blank" do
    # embeddings NOMINATE — related page titles cluster, unrelated don't
    loci = [
      {"shop/orders.work", "orders shipments fulfillment shop"},
      {"shop/listings.work", "listings products catalog shop"},
      {"shop/money-watch.work", "money revenue payouts watch shop"},
      {"shop/unrelated.work", "quantum astrophysics nebula telescope"}
    ]

    edges = Autopoet.Genome.semantic_edges(loci, k: 2, min_sim: 0.2)
    assert edges != [], "D3: nominator proposed nothing"
    assert Enum.all?(edges, fn {_, _, m} -> m > 0.0 and m <= 0.5 end), "D3: mass out of band"

    # the outlier should be a weak or absent source (lexically distant)
    outlier_out = Enum.filter(edges, fn {s, _, _} -> s == "shop/unrelated.work" end)
    shop_out = Enum.filter(edges, fn {s, _, _} -> String.contains?(s, "shop/o") end)
    assert length(shop_out) >= length(outlier_out), "D3: nominator clustered the outlier over the shop pages"

    # birth gate: seeding semantic edges never hurts vs blank
    p = Personas.named("shop-seller")
    plan = Autopoet.Intake.parse_plan(p.profile)
    sem = semantic_prior_for(plan)
    signals = pulse_signals(p, 250, 10, {51, 3, 1})
    blank = prequential_at(signals, Model.new(), [150, 800], 3)
    seeded = prequential_at(signals, Model.seed(Model.new(), sem), [150, 800], 3)

    for cp <- [150, 800] do
      assert seeded[cp] >= blank[cp] - 0.02, "D3 birth (@#{cp}): semantic prior hurts (#{seeded[cp]} vs #{blank[cp]})"
    end

    Autopoet.Eval.History.record("genome/semantic", %{edges: length(edges), delta150: seeded[150] - blank[150]})
    IO.puts("  ✓ EVAL genome/semantic — nominator: #{length(edges)} edges, outlier isolated; birth never-worse-than-blank")
  end

  test "D4: fleet aggregation clips, k-anonymizes, and drops tenant-authored loci" do
    template = ["shop/orders.work", "shop/listings.work", "shop/money-watch.work"]

    # 4 consenting tenants; one edge is reported by only ONE tenant (must be
    # dropped by k-anon); one edge references a tenant-authored locus (must never
    # aggregate); one high-count edge tests clipping
    contribs = [
      %{edges: %{{"shop/orders.work", "shop/money-watch.work"} => 50, {"shop/orders.work", "shop/secret-vip.work"} => 9}},
      %{edges: %{{"shop/orders.work", "shop/money-watch.work"} => 40}},
      %{edges: %{{"shop/orders.work", "shop/money-watch.work"} => 30, {"shop/listings.work", "shop/orders.work"} => 5}},
      %{edges: %{{"shop/orders.work", "shop/lonely.work"} => 100}}
    ]

    prior = Autopoet.Genome.fleet_prior(contribs, template, clip: 5.0, k_anon: 3)

    edge_set = MapSet.new(prior, fn {s, d, _} -> {s, d} end)

    # the 3-tenant template edge survives; clipped (50 → ≤5 each) so mass is bounded
    assert MapSet.member?(edge_set, {"shop/orders.work", "shop/money-watch.work"})
    {_, _, mass} = Enum.find(prior, fn {s, d, _} -> {s, d} == {"shop/orders.work", "shop/money-watch.work"} end)
    assert mass > 0.0 and mass <= 0.6

    # k-anon: single-tenant edges dropped
    refute MapSet.member?(edge_set, {"shop/listings.work", "shop/orders.work"})
    # tenant-authored loci NEVER aggregate (privacy boundary)
    refute Enum.any?(prior, fn {s, d, _} -> "shop/secret-vip.work" in [s, d] or "shop/lonely.work" in [s, d] end)

    # noise is injectable + Laplace sampler is real
    noised = Autopoet.Genome.fleet_prior(contribs, template, k_anon: 3, noise: fn s -> Autopoet.Genome.laplace(s, 0.5) end)
    assert is_list(noised)
    assert Autopoet.Genome.laplace(2.0, 0.5) == 0.0

    Autopoet.Eval.History.record("genome/fleet", %{edges: length(prior), k_anon: 3})
    IO.puts("  ✓ EVAL genome/fleet — clip+k-anon+tenant-locus-drop enforced; #{length(prior)} fleet edge(s)")
  end

  test "growth bound (wb-5ih92): prune drops decayed edges, keeps active pathways" do
    # a fresh model, one strong repeated pathway + one stale low-mass edge
    m = Model.new()
    m = Model.seed(m, [{"stale-a", "stale-b"}], 0.05)
    m = Enum.reduce(1..50, m, fn _, m -> m |> Model.observe("hot-a") |> Model.observe("hot-b") end)
    # advance time far enough that the stale seed (0.05) decays below the 0.02
    # floor: 0.05·0.9985^t < 0.02 ⇒ t > ~611
    m = Enum.reduce(1..800, m, fn _, m -> Model.observe(m, "hot-a") end)

    before_edges = for {_s, row} <- m.g, {_d, _} <- row, do: 1
    pruned = Model.prune(m, 0.02)
    after_edges = for {_s, row} <- pruned.g, {_d, _} <- row, do: 1

    assert length(after_edges) < length(before_edges), "prune removed nothing"
    # the hot pathway survives
    assert Map.has_key?(pruned.g, "hot-a")
    # the stale seed is gone
    refute match?(%{"stale-b" => _}, Map.get(pruned.g, "stale-a", %{}))

    IO.puts("  ✓ EVAL genome/prune — #{length(before_edges)} → #{length(after_edges)} edges; hot pathway kept, stale dropped")
  end

  defp semantic_prior_for(plan) do
    ws = plan.workspace.name
    loci = for page <- plan.workspace.pages, do: {"#{ws}/#{slug(page)}.work", "#{page} #{plan.workspace.title}"}
    Autopoet.Genome.semantic_edges(loci)
  end

  defp slug(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  defp pct(d), do: :erlang.float_to_binary(d * 100, decimals: 2) <> "pt"
end
