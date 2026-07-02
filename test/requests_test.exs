defmodule Autopoet.RequestsTest do
  use ExUnit.Case

  # The human-to-brain lane, through the REAL pieces: typed request (injection
  # firewall) -> bus event -> heartbeat effect (the registered autopoet.cycle) ->
  # brain -> pending proposal.

  test "a filed request flows through the real cycle effect into a direct body write" do
    fname = "from-request-#{System.unique_integer([:positive])}.work"
    written = Path.join(Autopoet.Body.root(), fname)

    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "=== file: #{fname} ===\n# From a request\n"}
    end)

    on_exit(fn ->
      Application.delete_env(:autopoet, :brain_llm)
      File.rm(written)
    end)

    Nexus.Events.subscribe()
    assert :ok = Autopoet.Requests.file("journal", "add a from-request page")
    assert_receive {:event, %{kind: "self_edit.requested"}}, 2_000
    Process.sleep(150)
    assert Autopoet.Requests.pending() != []

    # the exact effect the armed scheduler fires
    Nexus.Effects.run(%{name: "autopoet.cycle", args: %{}}, %{}, %{})

    # the cycle authors the body directly — the page exists immediately, no proposal
    assert wait_file(written), "the cycle did not author the requested page"
    assert File.read!(written) =~ "From a request"

    # queue drained; dedup key consumed
    assert Autopoet.Requests.pending() == []
  end

  defp wait_file(path, tries \\ 40) do
    cond do
      File.exists?(path) -> true
      tries <= 0 -> false
      true -> Process.sleep(25); wait_file(path, tries - 1)
    end
  end
  test "an AGENT-side request (bare bus event, the ungated bash verb path) reaches the queue" do
    Nexus.Events.emit(%{
      kind: "self_edit.requested",
      target: "research_limb",
      change: "search verb returned malformed results twice",
      dedup_key: "research_limb::search-malformed",
      tags: []
    })

    Process.sleep(150)
    assert Enum.any?(Autopoet.Requests.pending(), &(&1.target == "research_limb"))
  end
end
