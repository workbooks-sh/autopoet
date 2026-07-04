defmodule Autopoet.IntegrityEvalTest do
  @moduledoc """
  Eval D4 (wb-q351b.4) — feedback integrity, proven on the REAL capture trace
  this very suite produces (no synthetic shortcut: the events swept here went
  through the production bus, hook dispatch, supervised effect tasks, and the
  capture subscriber).

  GATES:
    G-SETTLE  every effect.settled in today's trace is well-formed and its
              cause resolves to a captured event.
    G-CHAIN   zero orphans — every `cause:` names an id present in the trace.
              (forward_refs tolerated: settle tasks can outrun the parent's
              broadcast by design; they still resolve.)
    G-CONSERVE folding a bus-produced segment through Outcomes.Model equals the
              LIVE ledger's cells for the same keys, and the fold is
              deterministic. Same arithmetic, one source of truth.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{Integrity, Replay}

  defp todays_trace, do: Path.join(Autopoet.Capture.dir(), Date.to_iso8601(Date.utc_today()) <> ".etfs")

  test "G-SETTLE + G-CHAIN: today's real capture trace holds the phase-0 invariants" do
    # G-SETTLE is gated on THIS test's window (pre-fix garbage from older runs of
    # the same day stays informational); G-CHAIN (zero orphans) gates the whole file.
    t0 = System.os_time(:second)

    # drive a real hook→effect→settle + a chained emit through the production bus
    uniq = "integ#{System.os_time(:millisecond)}#{System.unique_integer([:positive])}"
    Nexus.Effects.register("#{uniq}_eff", fn _a, _e, _c -> :ok end)

    Nexus.Hook.register(%{
      name: "#{uniq}_hook",
      match: %{tags: [uniq]},
      trigger: nil,
      title: uniq,
      visible_to: nil,
      effects: [%{name: "#{uniq}_eff", args: %{}}, %{name: "emit", args: %{kind: "#{uniq}.chained", tags: []}}]
    })

    for _ <- 1..10, do: Nexus.Events.emit(%{kind: "#{uniq}.fire", tags: [uniq]})
    Process.sleep(500)

    frames = Replay.frames(todays_trace())
    assert frames != [], "no capture trace for today"

    window = Enum.filter(frames, &((&1[:at] || 0) >= t0))
    settle = Integrity.settle_sweep(window)
    assert settle.violations == [],
           "G-SETTLE FAILED: #{length(settle.violations)} malformed/unresolved settles, e.g. #{inspect(Enum.take(settle.violations, 1))}"
    assert settle.settled == settle.well_formed
    assert settle.settled >= 20, "expected ≥20 settles from this test alone (2 effects × 10 fires)"

    chain = Integrity.chain_sweep(frames)
    assert chain.orphans == 0, "G-CHAIN FAILED: #{chain.orphans} orphaned cause ids"
    assert chain.caused >= 10, "chained emits missing from the trace"

    IO.puts(
      "  ✓ EVAL integrity/today (#{length(frames)} events) — settles #{settle.settled} all resolved · " <>
        "chains #{chain.caused} caused / #{chain.resolved} resolved / #{chain.forward_refs} forward / #{chain.orphans} orphans"
    )
  end

  test "G-CONSERVE: replaying a bus-produced segment reproduces the live ledger exactly" do
    uniq = "cons#{System.os_time(:millisecond)}#{System.unique_integer([:positive])}"
    Nexus.Effects.register("#{uniq}_eff", fn _a, _e, _c -> :ok end)

    Nexus.Hook.register(%{
      name: "#{uniq}_hook",
      match: %{tags: [uniq]},
      trigger: nil,
      title: uniq,
      visible_to: nil,
      effects: [%{name: "#{uniq}_eff", args: %{}}]
    })

    for _ <- 1..7, do: Nexus.Events.emit(%{kind: "#{uniq}.fire", tags: [uniq]})
    Nexus.Events.emit(%{kind: "proposal.recorded", proposal: "px", target: uniq, tags: []})
    Nexus.Events.emit(%{kind: "proposal.rejected", proposal: "px", target: uniq, tags: []})
    Process.sleep(500)

    frames = Replay.frames(todays_trace())
    ours = Enum.filter(frames, fn ev ->
      ev[:hook] == "#{uniq}_hook" or ev[:target] == uniq
    end)

    replayed = Integrity.replay_ledger(ours)

    # determinism: same segment, same ledger
    assert replayed == Integrity.replay_ledger(ours)

    # conservation vs the LIVE ledger (the GenServer folded the same events off the bus)
    live = Autopoet.Shadow.Outcomes.ledger()
    assert live.effects[{"#{uniq}_hook", "#{uniq}_eff"}] == replayed.effects[{"#{uniq}_hook", "#{uniq}_eff"}]
    assert replayed.effects[{"#{uniq}_hook", "#{uniq}_eff"}].ok == 7
    assert live.proposals[uniq] == replayed.proposals[uniq]
    assert replayed.proposals[uniq] == %{recorded: 1, accepted: 0, rejected: 1, reverted: 0}

    IO.puts("  ✓ EVAL integrity/conservation — live ledger == trace replay (#{map_size(replayed.effects)} effect key(s), #{map_size(replayed.proposals)} target(s))")
  end

  test "historical traces (informational): sweep whatever capture has on disk" do
    for path <- Path.wildcard(Path.join(Autopoet.Capture.dir(), "*.etfs")) |> Enum.take(3) do
      frames = Replay.frames(path)
      s = Integrity.settle_sweep(frames)
      c = Integrity.chain_sweep(frames)

      IO.puts(
        "  · EVAL integrity/#{Path.basename(path)} (#{length(frames)} ev) — " <>
          "settles #{s.cause_resolved}/#{s.settled} resolved · chains #{c.resolved}/#{c.caused} resolved, #{c.orphans} orphans"
      )
    end

    assert true
  end
end
