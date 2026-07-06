defmodule Autopoet.MicroTriageTest do
  use ExUnit.Case, async: true

  alias Autopoet.Shadow.Triage

  # Phase-1 SAFETY contract: with the micro-brain disabled (test config sets
  # `config :autopoet, Autopoet.Micro, enabled: false`), the shadow layer must
  # behave EXACTLY as it did before Phase 1 — no task spawned, no network touched,
  # no `autopoet.attention.triaged` event, zero added latency. The intelligence is
  # optional; the substrate degrading to "today" is not.

  test "micro-brain is disabled in the test env" do
    refute Autopoet.Micro.enabled?()
  end

  test "on_alarm is a no-op when disabled: returns :ok instantly, emits nothing" do
    Nexus.Events.subscribe()

    t0 = System.monotonic_time(:microsecond)
    assert :ok == Triage.on_alarm("treasury.refused", %{fast: 1.9, slow: 0.7})
    elapsed_us = System.monotonic_time(:microsecond) - t0

    # A gated config read + return — must be effectively free (no task, no probe).
    # Generous ceiling (5ms) so a loaded CI box never flakes; the point is "not a
    # network round-trip" (~1-2s), which this would be if it didn't short-circuit.
    assert elapsed_us < 5_000, "on_alarm took #{elapsed_us}us — it must not do work when disabled"

    # No triage event on the bus (give any stray async task room to misbehave).
    refute_receive {:event, %{kind: "autopoet.attention.triaged"}}, 200
  end

  test "suggest degrades to :unavailable when the model endpoint is down" do
    # Point at a dead port; available?/0 fails closed, suggest never calls decide.
    prev = Application.get_env(:autopoet, Autopoet.Micro, [])
    Application.put_env(:autopoet, Autopoet.Micro, Keyword.merge(prev, url: "http://127.0.0.1:1/v1/chat/completions"))
    on_exit(fn -> Application.put_env(:autopoet, Autopoet.Micro, prev) end)

    assert :unavailable == Triage.suggest("treasury.refused", %{fast: 1.9, slow: 0.7})
  end

  test "the diagnostic toolset and one-shot example are well-formed" do
    names = Enum.map(Triage.tools(), & &1.name)
    assert "recall" in names and "history" in names and "outcomes" in names and "explain" in names

    {situation, call} = Triage.example(:drift)
    assert is_binary(situation) and situation != ""
    # the example must itself be a parseable CALL (it's what teaches the format)
    assert Regex.match?(~r/^CALL\s+(recall|history|outcomes|explain)\s+\S/, call)
  end
end
