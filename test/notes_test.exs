defmodule Autopoet.NotesTest do
  use ExUnit.Case

  # The vault lane, end to end: note saved -> diff detected -> translation request
  # queued -> the real heartbeat cycle -> gated proposal. The typeaway model as
  # the standard: notes are the source of truth, .work is the translation target.

  test "vault basics: seed, tree, create both kinds, sketches are svg" do
    Autopoet.Notes.seed()
    assert Enum.any?(Autopoet.Notes.tree(), &(&1.name == "welcome.md"))

    assert :ok = Autopoet.Notes.create("thoughts/plan-#{System.unique_integer([:positive])}.md", "note")
    sketch = "draw-#{System.unique_integer([:positive])}.sketch.svg"
    assert :ok = Autopoet.Notes.create(sketch, "sketch")
    assert {:ok, svg} = Autopoet.Notes.read(sketch)
    assert svg =~ "<svg"
    assert Autopoet.Notes.kind(sketch) == "sketch"

    assert_raise ArgumentError, fn -> Autopoet.Notes.write("../escape.md", "no") end
  end

  test "a changed note files ONE translation request (diff-triggered, latest wins) and becomes a proposal" do
    Application.put_env(:autopoet, :brain_llm, fn prompt ->
      if prompt =~ "TRANSLATE A HUMAN NOTE" or prompt =~ "NOTE CONTENT" or true do
        {:ok, "=== append: journal.work ===\n- <2026-07-02 Thu> vault said: hello\n"}
      end
    end)
    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    Nexus.Events.subscribe()
    path = "vault-e2e-#{System.unique_integer([:positive])}.md"

    Autopoet.Notes.write(path, "please add a journal line saying hello")
    Process.sleep(150)
    assert Enum.any?(Autopoet.Requests.pending(), &(&1.target == "notes/#{path}"))

    # same content again -> no new request state change; new content -> replaces (keyed by target)
    Autopoet.Notes.write(path, "please add a journal line saying hello")
    Autopoet.Notes.write(path, "actually say hello TWICE")
    Process.sleep(150)
    matching = Enum.filter(Autopoet.Requests.pending(), &(&1.target == "notes/#{path}"))
    assert length(matching) == 1
    assert hd(matching).change =~ "TWICE"

    # the real heartbeat effect turns it into a gated proposal
    Nexus.Effects.run(%{name: "autopoet.cycle", args: %{}}, %{}, %{})
    assert_receive {:event, %{kind: "proposal.recorded", proposal: id}}, 3_000
    assert Autopoet.Proposals.status(id) == "pending"
  end
end
