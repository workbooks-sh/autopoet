defmodule Autopoet.ShadowTest do
  use ExUnit.Case

  # v2 shadow layer, proven through the REAL bus: pathways form from delivered
  # events; a workload shift raises an autopoet.attention event; observability
  # events are never learned.

  test "Hebbian pathways form from real bus traffic and drift raises attention" do
    Nexus.Events.subscribe()
    :rand.seed(:exsss, {9, 9, 9})

    # Stable regime, long enough for the slow EMA to settle (the measured envelope
    # from the chamber holds only past warmup): a repeating pathway a -> b -> c.
    for _ <- 1..500, doc <- ~w(shadow-a shadow-b shadow-c) do
      Nexus.Events.emit(%{kind: "doc.access", doc: doc, tags: []})
    end

    Process.sleep(400)
    hebb = Autopoet.Shadow.Hebb.stats()
    assert hebb.events >= 1500

    top_pairs = for {a, b, _w} <- hebb.top, do: {a, b}
    assert {"shadow-a", "shadow-b"} in top_pairs or {"shadow-b", "shadow-c"} in top_pairs

    baseline_alarms = Autopoet.Shadow.Surprise.stats().alarms

    # Regime shift: RANDOM transitions over an entirely new vocabulary — abrupt,
    # severe, persistently surprising (inside the detector's measured envelope;
    # a small deterministic cycle would become predictable within one lap and
    # legitimately NOT alarm).
    for _ <- 1..400 do
      Nexus.Events.emit(%{kind: "doc.access", doc: "novel-#{:rand.uniform(40)}", tags: []})
    end

    assert_receive {:event, %{kind: "autopoet.attention", reason: "drift"}}, 5_000
    Process.sleep(100)
    assert Autopoet.Shadow.Surprise.stats().alarms > baseline_alarms
  end

  test "observability events (settled/attention) are excluded from learning" do
    before = Autopoet.Shadow.Hebb.stats().events
    Nexus.Events.emit(%{kind: "effect.settled", hook: "x", effect: "y", status: :ok, tags: []})
    Nexus.Events.emit(%{kind: "autopoet.attention", reason: "drift", tags: []})
    Process.sleep(200)
    assert Autopoet.Shadow.Hebb.stats().events == before
  end
end
