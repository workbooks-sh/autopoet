defmodule Autopoet.RequestsTest do
  use ExUnit.Case

  # The human-to-brain lane, through the REAL pieces: typed request (injection
  # firewall) -> bus event -> heartbeat effect (the registered autopoet.cycle) ->
  # brain -> pending proposal.

  test "a filed request flows through the real cycle effect into a pending proposal" do
    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "=== file: from-request.work ===\n# From a request\n"}
    end)

    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    Nexus.Events.subscribe()
    assert :ok = Autopoet.Requests.file("journal", "add a from-request page")
    assert_receive {:event, %{kind: "self_edit.requested"}}, 2_000
    assert Autopoet.Requests.pending() != []

    # the exact effect the armed scheduler fires
    Nexus.Effects.run(%{name: "autopoet.cycle", args: %{}}, %{}, %{})

    assert_receive {:event, %{kind: "proposal.recorded", proposal: id}}, 3_000
    assert Autopoet.Proposals.status(id) == "pending"

    # queue drained; dedup key consumed
    assert Autopoet.Requests.pending() == []
  end
end
