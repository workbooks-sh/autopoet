defmodule Autopoet.BrainTest do
  use ExUnit.Case

  # v3 proposal-only mode, end to end with an injected LLM (no network):
  # sensed item -> brain -> proposal recorded -> HUMAN accept re-runs the real
  # Eval gate -> files land in the workbook tree. Reject archives. Nothing merges
  # without the human verb.

  setup do
    root = Path.join(Autopoet.Discovery.home(), "brain_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "index.work"), "# test nexus\n")
    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)
    {:ok, root: root}
  end

  # the cycle authors the body just off the calling process; poll briefly for the file
  defp wait_file(path, tries \\ 40) do
    cond do
      File.exists?(path) -> true
      tries <= 0 -> false
      true -> Process.sleep(25); wait_file(path, tries - 1)
    end
  end

  test "cycle with injected LLM writes the body DIRECTLY (no proposal)", %{root: root} do
    # unique filename: the body is ONE shared dir, so a per-test name keeps this
    # seed-independent (no clash with other cycle-driving tests writing journal.work)
    fname = "journal-#{System.unique_integer([:positive])}.work"
    written = Path.join(Autopoet.Body.root(), fname)
    on_exit(fn -> File.rm(written) end)

    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "=== file: #{fname} ===\n# Journal\n\nA page authored by the brain.\n"}
    end)

    report =
      Nexus.Autopoet.Worker.run_once(
        root: root,
        requests: [%{target: "journal", change: "add journal", evidence: []}],
        proposer: &Autopoet.Brain.propose/1,
        notify: &Autopoet.Brain.notify/2
      )

    assert report.sensed >= 1

    # the body is the agent's own — it authors it DIRECTLY: the file lands immediately,
    # no proposal, no accept. (Only the VAULT still routes through a gated proposal.)
    assert wait_file(written), "the cycle did not author the body page directly"
    assert File.read!(written) =~ "authored by the brain"
  end

  test "a proposal violating index purity is refused by the gate at accept time", %{root: root} do
    # Instrument facts learned probing this: (1) Nexus.Literate.parse/1 is fault-
    # tolerant and never raises — malformed code degrades to prose, so Eval's parse
    # check is a no-op in practice (filed); (2) purity requires WELL-FORMED units
    # (`server :name do` — a bare-identifier name isn't a unit at all). The realistic
    # smuggling case — a valid server unit inside index.work — IS refused:
    impure = "# index\n\nserver :smuggled do\n  def run(_), do: 1\nend\n"
    id = Autopoet.Proposals.record(%{target: "bad", kind: :request}, %{"index.work" => impure})
    assert {:error, :gate_failed} = Autopoet.Proposals.accept(id, root)
    assert Autopoet.Proposals.status(id) == "rejected-by-gate"
    refute File.read!(Path.join(root, "index.work")) =~ "smuggled"
  end

  test "reject archives without touching the tree", %{root: root} do
    id = Autopoet.Proposals.record(%{target: "x", kind: :request}, %{"x.work" => "# x\n"})
    assert :ok = Autopoet.Proposals.reject(id)
    assert Autopoet.Proposals.status(id) == "rejected"
    refute File.exists?(Path.join(root, "x.work"))
  end

  test "path traversal in a change set is refused" do
    assert_raise ArgumentError, fn ->
      Autopoet.Proposals.record(%{target: "evil"}, %{"../escape.work" => "# no\n"})
    end
  end

  test "without an injected LLM (and live mode off, as in all tests) the brain skips harmlessly" do
    Application.delete_env(:autopoet, :brain_llm)
    assert :skip = Autopoet.Brain.propose(%{target: "anything", kind: :concern})
  end
end
