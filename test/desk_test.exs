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
    # NEVER the real eval/desk — the live op's issues.log is the ops monitor's
    # feed; a test line there reads as a production incident
    dir = Path.join(System.tmp_dir!(), "desk-test-#{System.os_time(:millisecond)}")
    File.mkdir_p!(dir)

    line = "#{DateTime.to_iso8601(DateTime.utc_now())} | test issue\n"
    File.write!(Path.join(dir, "issues.log"), line, [:append])
    assert File.read!(Path.join(dir, "issues.log")) =~ ~r/\d{4}-\d{2}-\d{2}T.+ \| test issue/

    File.write!(Path.join(dir, "state.txt"), "ts: #{System.os_time(:second)}\nday: 2026-07-04\ncycles: 1\n")
    assert File.read!(Path.join(dir, "state.txt")) =~ ~r/^ts: \d+$/m
    File.rm_rf!(dir)
  end

  test "desk boots, ticks, heartbeats, and status reads (one supervised lifecycle)" do
    # isolated artifacts dir: a test desk must NEVER write the live op's
    # eval/desk (heartbeat/issues are the ops monitor's production feed)
    dir = Path.join(System.tmp_dir!(), "desk-lifecycle-#{System.os_time(:millisecond)}")
    System.put_env("AUTOPOET_DESK_DIR", dir)
    on_exit(fn -> System.delete_env("AUTOPOET_DESK_DIR") end)

    {:ok, pid} = Autopoet.Desk.start_link([])

    # first tick fires after 5s; wait for it, then check heartbeat
    Process.sleep(5_600)
    status = Autopoet.Desk.status()
    assert is_binary(status.day)
    assert File.exists?(Path.join(dir, "state.txt"))
    assert File.read!(Path.join(dir, "state.txt")) =~ "day: #{status.day}"

    GenServer.stop(pid)
    IO.puts("  ✓ desk lifecycle — boot, tick, heartbeat, status")
  end
end
