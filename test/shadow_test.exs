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
    # settles emitted here are WELL-FORMED (cause resolves) so the shared capture
    # trace stays integrity-clean — the D4 sweeps run over this same day file
    parent = Nexus.Events.emit(%{kind: "shadow.parent", tags: []})
    Nexus.Events.emit(%{kind: "effect.settled", hook: "x", effect: "y", status: :ok, duration_us: 1, cause: parent[:id], tags: []})
    Nexus.Events.emit(%{kind: "autopoet.attention", reason: "drift", tags: []})
    Process.sleep(200)
    # the workload parent learns; the two observability events do not
    assert Autopoet.Shadow.Hebb.stats().events == before + 1
  end

  # Phase 0 (nothing is lost): learner state survives a hard process restart.
  test "Hebb + Surprise + Outcomes state survives a reboot" do
    for doc <- ~w(dur-a dur-b dur-a dur-b) do
      Nexus.Events.emit(%{kind: "doc.access", doc: doc, tags: []})
    end

    Process.sleep(200)
    hebb_before = Autopoet.Shadow.Hebb.stats()
    surprise_before = Autopoet.Shadow.Surprise.stats()
    assert hebb_before.events >= 4

    :ok = Autopoet.Shadow.Hebb.snapshot()
    :ok = Autopoet.Shadow.Surprise.snapshot()
    :ok = Autopoet.Shadow.Outcomes.snapshot()

    # hard reboot: the supervisor restarts each learner, which restores from disk
    GenServer.stop(Autopoet.Shadow.Hebb)
    GenServer.stop(Autopoet.Shadow.Surprise)
    GenServer.stop(Autopoet.Shadow.Outcomes)
    Process.sleep(300)

    assert Autopoet.Shadow.Hebb.stats().events >= hebb_before.events
    assert Autopoet.Shadow.Hebb.stats().edges >= 1
    assert Autopoet.Shadow.Surprise.stats().events >= surprise_before.events
    assert is_integer(Autopoet.Shadow.Outcomes.stats().observed)
  end

  # The first actuator (ladder rung 4): weighted recall RANKS learned pathways.
  test "recall ranks direct pathway above 2-hop, unknown locus recalls nothing" do
    for _ <- 1..30, doc <- ~w(rec-a rec-b rec-c) do
      Nexus.Events.emit(%{kind: "doc.access", doc: doc, tags: []})
    end

    Process.sleep(300)
    recalled = Autopoet.Shadow.Hebb.recall("rec-a", 5)
    assert [{first, _} | _] = recalled
    assert first == "rec-b", "direct neighbor must outrank 2-hop (got #{inspect(recalled)})"
    # 2-hop reach: rec-c is visible from rec-a through rec-b, damped below rec-b
    loci = Enum.map(recalled, &elem(&1, 0))
    assert "rec-c" in loci

    assert Autopoet.Shadow.Hebb.recall("never-seen-locus", 5) == []
  end

  # The feedback half of the loop: settlements and proposal verdicts land in the ledger.
  test "Outcomes ledger records effect settlements and proposal verdicts" do
    before = Autopoet.Shadow.Outcomes.stats()

    parent = Nexus.Events.emit(%{kind: "led.parent", tags: []})
    Nexus.Events.emit(%{kind: "effect.settled", hook: "led-hook", effect: "led-eff", status: :ok, duration_us: 42, cause: parent[:id], tags: []})
    Nexus.Events.emit(%{kind: "effect.settled", hook: "led-hook", effect: "led-eff", status: :error, duration_us: 7, cause: parent[:id], tags: []})
    Nexus.Events.emit(%{kind: "proposal.recorded", proposal: "p1", target: "led-target", tags: []})
    Nexus.Events.emit(%{kind: "proposal.accepted", proposal: "p1", target: "led-target", tags: []})

    Process.sleep(300)
    stats = Autopoet.Shadow.Outcomes.stats()
    assert stats.settled.ok >= before.settled.ok + 1
    assert stats.settled.error >= before.settled.error + 1
    assert stats.proposals.accepted >= before.proposals.accepted + 1

    ledger = Autopoet.Shadow.Outcomes.ledger()
    assert %{ok: 1, error: 1, us: 49} = ledger.effects[{"led-hook", "led-eff"}]
    assert %{recorded: 1, accepted: 1} = ledger.proposals["led-target"]
  end
end
