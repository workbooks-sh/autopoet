defmodule Autopoet.RequestsDurabilityTest do
  use ExUnit.Case

  test "queued requests persist to disk and reload after a process restart; drain removes them" do
    Nexus.Events.emit(%{
      kind: "self_edit.requested",
      target: "durability",
      change: "survive the restart",
      dedup_key: "durability::survive",
      tags: []
    })

    Process.sleep(150)
    assert Enum.any?(Autopoet.Requests.pending(), &(&1.target == "durability"))
    assert Path.wildcard(Path.join(Autopoet.Requests.dir(), "*.req")) != []

    # kill the process; the supervisor restarts it; state must come back from disk
    GenServer.stop(Autopoet.Requests)

    reloaded =
      Enum.find_value(1..50, fn _ ->
        Process.sleep(50)

        case Process.whereis(Autopoet.Requests) do
          nil -> nil
          _pid -> (Enum.any?(Autopoet.Requests.pending(), &(&1.target == "durability")) && true) || nil
        end
      end)

    assert reloaded, "pending request did not survive the restart"

    Autopoet.Requests.drain()
    assert Path.wildcard(Path.join(Autopoet.Requests.dir(), "*.req")) == []
  end
end
