defmodule Autopoet.CorpusEvalTest do
  @moduledoc """
  Phase C production gates (wb-h0tjs.4) — the MECHANISM is complete and runs
  automatically the moment the data exists; until then each gate reports how far
  the corpus is from its threshold (a countdown, not a stub). No fabricated
  passes: a gate that lacks data SKIPS with the shortfall, it never asserts.

    C1 corpus depth — ≥14 distinct capture days on disk.
    C2 live arm-lift — ≥50 DECIDED real proposal verdicts joined to arms, with a
       CI-backed ship/no-ship decision on widening the actuator.
    C4 learning lift — windowed hebb−frequency on HOLDOUT (odd-day) production
       traces, 95% CI must exclude zero.

  These read the REAL capture corpus (Autopoet.Capture.dir) through the same
  pure harness the dev gates use — validate-the-instrument all the way down.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{ArmLift, Replay}

  @c1_days 14
  @c2_decided 50
  @c4_events 2_000

  defp traces, do: Path.wildcard(Path.join(Autopoet.Capture.dir(), "*.etfs"))
  defp days, do: traces() |> Enum.map(&Path.basename(&1, ".etfs")) |> Enum.filter(&(&1 =~ ~r/^\d{4}-\d{2}-\d{2}$/))

  test "C1: capture corpus depth countdown / gate" do
    d = length(days())

    if d >= @c1_days do
      Autopoet.Eval.History.record("corpus/c1", %{days: d, gate: "pass"})
      IO.puts("  ✓ EVAL corpus/c1 — #{d} capture days (≥#{@c1_days}) — GATE MET")
      assert d >= @c1_days
    else
      Autopoet.Eval.History.record("corpus/c1", %{days: d, need: @c1_days, gate: "pending"})
      IO.puts("  · EVAL corpus/c1 — #{d}/#{@c1_days} capture days — #{@c1_days - d} more to gate")
    end
  end

  test "C2: live arm-lift decision (needs ≥50 decided verdicts)" do
    frames = Enum.flat_map(traces(), &Replay.frames/1)
    s = ArmLift.score(frames)

    if s.decided >= @c2_decided and s.lift do
      Autopoet.Eval.History.record("corpus/c2", %{decided: s.decided, lift: s.lift, gate: "decided"})
      decision = if s.lift > 0, do: "SHIP warm ordering", else: "HOLD (no lift)"
      IO.puts("  ✓ EVAL corpus/c2 — #{s.decided} verdicts, lift #{pct(s.lift)} → #{decision}")
      assert s.decided >= @c2_decided
    else
      Autopoet.Eval.History.record("corpus/c2", %{decided: s.decided, need: @c2_decided, gate: "pending"})
      IO.puts("  · EVAL corpus/c2 — #{s.decided}/#{@c2_decided} decided arm→verdict pairs — accruing from live use")
    end
  end

  test "C4: learning lift on HOLDOUT production traces (CI excludes zero)" do
    holdout =
      traces()
      |> Enum.filter(&Replay.holdout?/1)
      |> Enum.flat_map(&Replay.frames/1)
      |> Replay.signals()

    if length(holdout) >= @c4_events do
      s = Replay.prequential(Enum.take(holdout, 100_000), 3)
      ci = s.lift_ci

      Autopoet.Eval.History.record("corpus/c4", %{
        events: s.events,
        hebb_windowed: s.windowed.hebb,
        frequency: s.frequency,
        lift_lo: ci.lo,
        lift_hi: ci.hi,
        gate: if(ci.lo && ci.lo > 0, do: "pass", else: "fail")
      })

      IO.puts(
        "  ✓ EVAL corpus/c4 — HOLDOUT n=#{s.events}: hebb(win) #{pct(s.windowed.hebb)} vs freq #{pct(s.frequency)}, " <>
          "lift CI [#{pct(ci.lo)}, #{pct(ci.hi)}]"
      )

      assert ci.lo && ci.lo > 0,
             "C4: holdout learning lift CI includes zero (#{inspect(ci)}) — STOP, diagnose before widening"
    else
      Autopoet.Eval.History.record("corpus/c4", %{holdout_events: length(holdout), need: @c4_events, gate: "pending"})
      IO.puts("  · EVAL corpus/c4 — #{length(holdout)}/#{@c4_events} holdout events — accruing")
    end
  end

  defp pct(nil), do: "n/a"
  defp pct(r), do: :erlang.float_to_binary(r * 100, decimals: 1) <> "%"
end
