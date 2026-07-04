defmodule Autopoet.NotesTest do
  use ExUnit.Case

  # The vault lane, end to end: note saved -> diff detected -> translation request
  # queued -> the real heartbeat cycle -> the body authored DIRECTLY. The typeaway
  # model as the standard: notes are the source of truth, .work is the body the
  # agent authors from them.

  defp wait_file(path, tries \\ 40) do
    cond do
      File.exists?(path) -> true
      tries <= 0 -> false
      true -> Process.sleep(25); wait_file(path, tries - 1)
    end
  end

  test "vault basics: seed, tree, create both kinds, sketches are svg" do
    # GENESIS: seed only ensures dirs — no welcome.md demo (the vault is born
    # from the accepted first proposal); a lingering welcome.md here is debris
    Autopoet.Notes.seed()
    assert is_list(Autopoet.Notes.tree())

    # names salted with os_time: unique_integer restarts per VM and collides
    # with debris from previous runs in the shared test vault
    salt = "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
    assert :ok = Autopoet.Notes.create("thoughts/plan-#{salt}.md", "note")
    sketch = "draw-#{salt}.sketch.svg"
    assert :ok = Autopoet.Notes.create(sketch, "sketch")
    assert {:ok, svg} = Autopoet.Notes.read(sketch)
    assert svg =~ "<svg"
    assert Autopoet.Notes.kind(sketch) == "sketch"

    assert_raise ArgumentError, fn -> Autopoet.Notes.write("../escape.md", "no") end
  end

  test "a changed note files ONE translation request (diff-triggered, latest wins) and authors the body" do
    fname = "journal-#{System.unique_integer([:positive])}.work"
    written = Path.join(Autopoet.Body.root(), fname)

    Application.put_env(:autopoet, :brain_llm, fn prompt ->
      if prompt =~ "TRANSLATE A HUMAN NOTE" or prompt =~ "NOTE CONTENT" or true do
        {:ok, "=== append: #{fname} ===\n- <2026-07-02 Thu> vault said: hello\n"}
      end
    end)

    on_exit(fn ->
      Application.delete_env(:autopoet, :brain_llm)
      File.rm(written)
    end)

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

    # the real heartbeat effect translates the note into the body DIRECTLY (a human
    # note is the source; the resulting page is the agent's body, so it's authored — not proposed)
    Nexus.Effects.run(%{name: "autopoet.cycle", args: %{}}, %{}, %{})
    assert wait_file(written), "the cycle did not author the body from the note"
    assert File.read!(written) =~ "vault said: hello"
  end

  test "rename keeps kind sticky (content sniff), delete works, set-list order persists" do
    n = System.unique_integer([:positive])
    sk = "sticky-#{n}.sketch.svg"
    assert :ok = Autopoet.Notes.create(sk, "sketch")

    # rename away the extension — still a sketch (content sniff)
    assert :ok = Autopoet.Notes.rename(sk, "sticky-#{n}")
    tree = Autopoet.Notes.tree()
    assert Enum.find(tree, &(&1.name == "sticky-#{n}")).type == "sketch"

    # no extension on a text file = document
    assert :ok = Autopoet.Notes.create("plain-#{n}", "note")
    assert Enum.find(Autopoet.Notes.tree(), &(&1.name == "plain-#{n}")).type == "note"

    # set-list order: reversed order persists over alphabetical
    Autopoet.Notes.reorder("", ["plain-#{n}", "sticky-#{n}"])
    names = Autopoet.Notes.tree() |> Enum.map(& &1.name)
    assert Enum.find_index(names, &(&1 == "plain-#{n}")) < Enum.find_index(names, &(&1 == "sticky-#{n}"))

    # move into a folder via rename (the drag-drop path), then delete
    assert :ok = Autopoet.Notes.create("box-#{n}", "folder")
    assert :ok = Autopoet.Notes.rename("plain-#{n}", "box-#{n}/plain-#{n}")
    assert {:ok, _} = Autopoet.Notes.read("box-#{n}/plain-#{n}")
    assert :ok = Autopoet.Notes.delete("box-#{n}")
    assert {:error, _} = Autopoet.Notes.read("box-#{n}/plain-#{n}")
  end
end
