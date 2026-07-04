defmodule Autopoet.LiveEvalTest do
  @moduledoc """
  v2-2 — the LIVE tier (real LLM, real money, real quality measurement).

  DOUBLE-LOCKED so it can never fire by accident: tagged :live (excluded from
  mix test / mix eval) AND requires AUTOPOET_LIVE=1. Run via:

      AUTOPOET_LIVE=1 mix eval.live

  OBSERVATIONAL POSTURE (owner decree — monitor before gating): the canary run
  asserts only that the harness completed and every transcript exists; the
  pass-rate is REPORTED, reviewed by a human, and only then do pre-registered
  gates land. Spend is structurally bounded: one persona, sequential tasks,
  early-stop after 2 consecutive failures, max_tokens per call.
  """
  use ExUnit.Case, async: false
  @moduletag :live
  @moduletag timeout: :infinity

  test "canary: shop-seller through the REAL brain — transcribed, budgeted, observational" do
    unless System.get_env("AUTOPOET_LIVE") == "1" do
      IO.puts("  · LIVE canary skipped (set AUTOPOET_LIVE=1 to run — costs real provider credits)")
      assert true
    else
      assert Autopoet.Providers.openrouter?() or is_binary(Nexus.Secrets.get("OPENROUTER_API_KEY")),
             "no provider key reachable — live tier needs OPENROUTER or the gateway"

      # the live tier flips providers on for THIS run only (test config keeps
      # brain_live false so nothing else in the suite can go live)
      Application.put_env(:autopoet, :brain_live, true)
      on_exit(fn -> Application.put_env(:autopoet, :brain_live, false) end)

      # AUTOPOET_LIVE_PERSONAS widens the run (comma-separated or "all");
      # default stays the single-persona canary
      personas =
        case System.get_env("AUTOPOET_LIVE_PERSONAS") do
          nil -> ["shop-seller"]
          "all" -> Autopoet.Eval.Tasks.personas()
          csv -> String.split(csv, ",", trim: true)
        end

      stamp = "canary-#{System.os_time(:second)}"

      summaries =
        for persona <- personas do
          s = Autopoet.Eval.LiveRunner.run(persona, stamp: "#{stamp}/#{persona}", max_error_streak: 2)
          IO.puts("  ✓ LIVE #{persona} — #{s.passed}/#{s.total} artifacts · #{s.calls} calls · ~$#{Float.round(s.cost * 1.0, 4)}")
          s
        end

      passed = summaries |> Enum.map(& &1.passed) |> Enum.sum()
      total = summaries |> Enum.map(& &1.total) |> Enum.sum()
      cost = summaries |> Enum.map(& &1.cost) |> Enum.sum()

      IO.puts("  ✓ LIVE tier — #{passed}/#{total} across #{length(personas)} persona(s) · ~$#{Float.round(cost * 1.0, 4)} · eval/live-runs/#{stamp}")

      # harness invariants only (observational run): transcripts + reports exist
      for s <- summaries do
        assert File.exists?(Path.join(s.dir, "report.md"))
        assert Path.wildcard(Path.join(s.dir, "*-l*.md")) != [], "no transcripts in #{s.dir}"
      end
    end
  end
end
