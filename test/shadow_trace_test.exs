defmodule Autopoet.ShadowTraceTest do
  use ExUnit.Case, async: true

  alias Autopoet.Shadow.Trace

  @moduledoc false
  # Locks the corpus-analysis pipeline: the framed-ETF reader must round-trip
  # exactly what Autopoet.Capture writes (incl. a crash-torn tail), the workload
  # filter/signal must match the live learners, and the higher-order gate must
  # detect planted 2-back structure and report first-order-sufficiency otherwise.

  # Write frames the way Autopoet.Capture does: <<size::32, term_to_binary(ev)>>.
  defp write_frames(path, events) do
    bin = for ev <- events, into: <<>> do
      blob = :erlang.term_to_binary(ev)
      <<byte_size(blob)::32, blob::binary>>
    end

    File.write!(path, bin)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "trace_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "data/traces"))
    {:ok, root: dir, tdir: Path.join(dir, "data/traces")}
  end

  test "reads framed events across date files, in order; skips a torn tail frame", %{tdir: tdir} do
    write_frames(Path.join(tdir, "2026-07-05.etfs"), [
      %{kind: "proposal.recorded", doc: "a"},
      %{kind: "body.wrote", doc: "b"}
    ])

    # a valid frame + a deliberately truncated trailing frame (crash simulation)
    good = :erlang.term_to_binary(%{kind: "effect.settled", doc: "c"})
    torn = :erlang.term_to_binary(%{kind: "reward.landed", doc: "d"})
    File.write!(Path.join(tdir, "2026-07-06.etfs"),
      <<byte_size(good)::32, good::binary, byte_size(torn)::32, binary_part(torn, 0, 3)::binary>>)

    events = Trace.events(tdir)
    kinds = Enum.map(events, & &1[:kind])
    # both good files read, chronological; torn tail dropped, earlier frames kept
    assert kinds == ["proposal.recorded", "body.wrote", "effect.settled"]
  end

  test "ignores non-date files (telemetry etc.)", %{tdir: tdir} do
    write_frames(Path.join(tdir, "2026-07-06.etfs"), [%{kind: "body.wrote", doc: "b"}])
    write_frames(Path.join(tdir, "telemetry.etfs"), [%{kind: "should.not.appear", doc: "x"}])
    assert Trace.events(tdir) |> Enum.map(& &1[:kind]) == ["body.wrote"]
  end

  test "signals honor the workload filter and the :kind vs :doc lens", %{} do
    events = [
      %{kind: "body.wrote", doc: "notes/x"},
      %{kind: "effect.settled", doc: "notes/x"},          # observability — filtered out
      %{kind: "proposal.recorded", target: "agent"}
    ]

    # :doc lens uses doc||target||kind (live signal); effect.settled is observability
    assert Trace.signals(events, :doc) == ["notes/x", "agent"]
    # :kind lens collapses to the event kind
    assert Trace.signals(events, :kind) == ["body.wrote", "proposal.recorded"]
  end

  test "order_gate detects planted 2-back structure vs a first-order stream" do
    # STREAM A: higher-order — 'c' is lawful after [a,b] but unlawful (anomalous
    # symbol 'x') never appears; first vs second order bits should differ where
    # the 2-back context disambiguates a symbol the 1-back cannot.
    higher =
      Stream.cycle(["a", "b", "c", "d", "b", "e"]) |> Enum.take(1200)

    g = Trace.order_gate(higher, min_ctx: 2)
    assert g[1].bits >= g[2].bits, "2-back should predict at least as well as 1-back on structured data"
    assert g.meta.events == 1200

    # STREAM B: purely random over a small alphabet — no order structure; higher
    # order must NOT meaningfully beat first order (within noise).
    :rand.seed(:exsss, {1, 2, 3})
    rand = for _ <- 1..1200, do: Enum.random(~w(a b c d))
    gr = Trace.order_gate(rand, min_ctx: 2)
    assert gr.verdict in [:first_order_sufficient, :need_more_traces]
  end

  test "verdict is data-safe on an empty/tiny corpus", %{tdir: tdir} do
    assert Trace.events(tdir) == []
    g = Trace.order_gate(["a", "b", "a"], min_ctx: 3)
    assert g.verdict in [:insufficient_data, :need_more_traces]
  end

  test "triples link decision → verdict → market reward, and score feature-completeness" do
    events = [
      # a decision WITH context features → accepted → target earns a reward
      %{kind: "proposal.recorded", proposal: "p1", target: "shop/x",
        context: %{sensed: "concern", reasons: ["drift on shop/x"], summary: "fix x", paths: ["shop/x.work"]}},
      %{kind: "proposal.accepted", proposal: "p1", target: "shop/x"},
      %{kind: "reward.landed", target: "shop/x", amount: 1.0},
      # a pre-enrichment decision (no context) → rejected, no reward
      %{kind: "proposal.recorded", proposal: "p2", target: "shop/y"},
      %{kind: "proposal.rejected", proposal: "p2", target: "shop/y"},
      # a still-pending decision with context
      %{kind: "proposal.recorded", proposal: "p3", target: "shop/z",
        context: %{sensed: "request", reasons: [], summary: "", paths: ["shop/z.work"]}}
    ]

    triples = Trace.triples(events)
    p1 = Enum.find(triples, &(&1.proposal == "p1"))
    assert p1.verdict == "accepted" and p1.reward == 1.0 and p1.feature_complete?
    p2 = Enum.find(triples, &(&1.proposal == "p2"))
    assert p2.verdict == "rejected" and p2.reward == 0.0
    refute p2.feature_complete?, "a context-less (pre-enrichment) decision is not feature-complete"
    assert Enum.find(triples, &(&1.proposal == "p3")).verdict == "pending"

    s = Trace.label_stats(triples)
    assert s.decisions == 3
    assert s.proxy_labeled == 2
    assert s.market_labeled == 1
    assert s.feature_complete == 2  # p1 (paths+reasons) and p3 (paths)
    assert s.verdicts["accepted"] == 1 and s.verdicts["rejected"] == 1 and s.verdicts["pending"] == 1
  end

  test "reward joins to the decision via the :cause chain when targets differ (the trader case)" do
    # A trade decision on 'action:alpaca_place_order' → order event (caused by the
    # decision) → PnL reward keyed on the SYMBOL 'AAPL' (a different target). Only
    # the cause chain links the reward back to the decision.
    events = [
      %{kind: "proposal.recorded", id: "e1", proposal: "pT", target: "action:alpaca_place_order",
        context: %{sensed: "action.gated", reasons: [], summary: "buy AAPL", paths: []}},
      %{kind: "effect.settled", id: "e2", cause: "e1", status: :ok},
      %{kind: "reward.landed", id: "e3", cause: "e2", target: "AAPL", amount: 42.0}
    ]

    [t] = Trace.triples(events)
    assert t.proposal == "pT"
    assert t.reward == 42.0, "PnL must link to the decision through the cause chain"
    assert t.reward_via == :cause
    assert Trace.label_stats([t]).market_labeled == 1
  end
end
