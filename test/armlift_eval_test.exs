defmodule Autopoet.ArmLiftEvalTest do
  @moduledoc """
  wb-8lxzv — the arm-lift experiment, end to end through the REAL lane:
  pinned arm → context_order emits `recall.ab` → the brain drafts a
  triad-gated changeset → PENDING proposal → human verdict → all captured →
  the scorer joins arm→proposal→verdict from the trace alone.

  The synthetic pattern is known (warm: 3 accept / 1 reject; flat: 1 / 3), so
  the scorer's output is exact: warm 75%, flat 25%, lift +50pt. Production
  traces are then scored informationally — THAT number, accumulating in
  eval/history.log run over run, is the PLAN phase-1 KPI that decides whether
  the actuator widens.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{ArmLift, Replay}

  defp todays_trace, do: Path.join(Autopoet.Capture.dir(), Date.to_iso8601(Date.utc_today()) <> ".etfs")

  test "arm-lift scorer recovers the exact verdict pattern from the real trace" do
    t0 = System.os_time(:second)
    uniq = "ab#{System.unique_integer([:positive])}"
    on_exit(fn -> Application.delete_env(:autopoet, :recall_ab) end)

    # 8 rounds: 4 warm / 4 flat, verdicts in a known pattern
    plan = [
      {:warm, :accept}, {:warm, :accept}, {:warm, :accept}, {:warm, :reject},
      {:flat, :accept}, {:flat, :reject}, {:flat, :reject}, {:flat, :reject}
    ]

    for {{arm, verdict}, i} <- Enum.with_index(plan) do
      target = "#{uniq}-#{i}"
      rel = "crew/#{target}.work"
      body_file = Path.join(Autopoet.Body.root(), rel)
      File.mkdir_p!(Path.dirname(body_file))
      File.write!(body_file, "# crew\n\nagent :#{String.replace(target, "-", "_")} do\n  prompt \"watch\"\n  grant net\nend\n")
      on_exit(fn -> File.rm(body_file) end)

      # the brain widens the grant → triad-gated → held as a PENDING proposal
      Application.put_env(:autopoet, :recall_ab, arm)

      Application.put_env(:autopoet, :brain_llm, fn _prompt ->
        {:ok, "=== file: #{rel} ===\n# crew\n\nagent :#{String.replace(target, "-", "_")} do\n  prompt \"watch\"\n  grant net, secrets\nend\n"}
      end)

      Nexus.Autopoet.Worker.run_once(
        root: Autopoet.Body.root(),
        requests: [%{target: target, change: "tune the watcher"}],
        proposer: &Autopoet.Brain.propose/1,
        notify: fn _, _ -> :ok end,
        # suppress telemetry concerns — this experiment is request-driven only
        min_runs: 999_999_999
      )

      {id, _} =
        Autopoet.Proposals.pending()
        |> Enum.find(fn {pid, _} -> Autopoet.Proposals.target_of(pid) == target end) ||
          flunk("round #{i}: no pending proposal for #{target}")

      case verdict do
        :accept -> :ok = Autopoet.Proposals.accept(id, Autopoet.Body.root())
        :reject -> :ok = Autopoet.Proposals.reject(id, "eval pattern")
      end
    end

    Application.delete_env(:autopoet, :brain_llm)
    Process.sleep(500)

    window = Replay.frames(todays_trace()) |> Enum.filter(&((&1[:at] || 0) >= t0))
    scores = ArmLift.score(window)

    assert scores.warm.proposals == 4
    assert scores.flat.proposals == 4
    assert scores.warm.accepted == 3 and scores.warm.rejected == 1
    assert scores.flat.accepted == 1 and scores.flat.rejected == 3
    assert_in_delta scores.warm.rate, 0.75, 1.0e-9
    assert_in_delta scores.flat.rate, 0.25, 1.0e-9
    assert_in_delta scores.lift, 0.5, 1.0e-9
    assert scores.decided == 8

    Autopoet.Eval.History.record("recall-ab/synthetic", %{
      warm_rate: scores.warm.rate,
      flat_rate: scores.flat.rate,
      lift: scores.lift,
      decided: scores.decided
    })

    IO.puts(
      "  ✓ EVAL recall-ab — scorer exact: warm #{pct(scores.warm.rate)} (#{scores.warm.accepted}/#{scores.warm.accepted + scores.warm.rejected}) · " <>
        "flat #{pct(scores.flat.rate)} · lift +#{pct(scores.lift)}"
    )
  end

  test "production traces (informational): the live arm-lift KPI" do
    for path <- Path.wildcard(Path.join(Autopoet.Capture.dir(), "*.etfs")) |> Enum.take(3) do
      s = path |> Replay.frames() |> ArmLift.score()

      IO.puts(
        "  · EVAL recall-ab/#{Path.basename(path)} — warm #{s.warm.assigned} assigned/#{s.warm.proposals} proposals · " <>
          "flat #{s.flat.assigned}/#{s.flat.proposals} · decided #{s.decided} · lift #{if s.lift, do: pct(s.lift), else: "n/a (needs live verdicts)"}"
      )

      if s.lift do
        Autopoet.Eval.History.record("recall-ab/trace-#{Path.basename(path, ".etfs")}", %{
          warm_rate: s.warm.rate, flat_rate: s.flat.rate, lift: s.lift, decided: s.decided
        })
      end
    end

    assert true
  end

  defp pct(nil), do: "n/a"
  defp pct(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
end
