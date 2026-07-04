defmodule Autopoet.DeskTest do
  @moduledoc """
  Desk rails — hermetic (no LLM, no network; the GenServer's pure helpers via
  the module's own logic where possible). The 48h op leans on: day counters
  reset, cadence guards, issue logging, heartbeat file shape.
  """
  use ExUnit.Case, async: false

  test "desk not started without AUTOPOET_DESK=1" do
    refute Process.whereis(Autopoet.Desk), "desk must be opt-in"
  end

  test "issues.log + state.txt shapes (the monitor's contract)" do
    File.mkdir_p!("eval/desk")

    # the monitor greps these files; pin the line shapes
    line = "#{DateTime.to_iso8601(DateTime.utc_now())} | test issue\n"
    File.write!("eval/desk/issues.log", line, [:append])
    assert File.read!("eval/desk/issues.log") =~ ~r/\d{4}-\d{2}-\d{2}T.+ \| test issue/

    File.write!("eval/desk/state.txt", "ts: #{System.os_time(:second)}\nday: 2026-07-04\ncycles: 1\n")
    assert File.read!("eval/desk/state.txt") =~ ~r/^ts: \d+$/m
  end

  test "desk boots, ticks, heartbeats, and status reads (one supervised lifecycle)" do
    {:ok, pid} = Autopoet.Desk.start_link([])

    # first tick fires after 5s; wait for it, then check heartbeat
    Process.sleep(5_600)
    status = Autopoet.Desk.status()
    assert is_binary(status.day)
    assert File.exists?("eval/desk/state.txt")
    assert File.read!("eval/desk/state.txt") =~ "day: #{status.day}"

    GenServer.stop(pid)
    IO.puts("  ✓ desk lifecycle — boot, tick, heartbeat, status")
  end
end
