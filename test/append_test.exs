defmodule Autopoet.AppendTest do
  use ExUnit.Case

  test "append blocks add to a file's end at accept time; revert restores; content is never clobbered" do
    root = Path.join(Autopoet.Discovery.home(), "append_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "index.work"), "# index\n")
    File.write!(Path.join(root, "rules.work"), "# rules\n\n- rule one\n")

    id =
      Autopoet.Proposals.record(%{target: "rules", kind: :request}, %{}, %{
        "rules.work" => "- rule two (appended)\n"
      })

    assert :ok = Autopoet.Proposals.accept(id, root)
    content = File.read!(Path.join(root, "rules.work"))
    assert content =~ "- rule one"
    assert content =~ "- rule two (appended)"
    assert String.starts_with?(content, "# rules")

    assert :ok = Autopoet.Proposals.revert(id, root)
    assert File.read!(Path.join(root, "rules.work")) == "# rules\n\n- rule one\n"
  end

  test "the brain parses mixed file/append blocks and authors them into the body" do
    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "Plan or draft, same reply: === file: new.work ===\n# new\n=== append: journal.work ===\n- appended line\n" |> String.replace("Plan or draft, same reply: ", "")}
    end)

    on_exit(fn ->
      Application.delete_env(:autopoet, :brain_llm)
      File.rm(Path.join(Autopoet.Body.root(), "new.work"))
      File.rm(Path.join(Autopoet.Body.root(), "journal.work"))
    end)

    assert {:ok, changes} = Autopoet.Brain.propose(%{target: "journal", change: "append test"})
    assert Map.has_key?(changes, "new.work")
    assert Map.has_key?(changes, "journal.work")

    # direct-write: both files are now in the body immediately
    assert File.read!(Path.join(Autopoet.Body.root(), "new.work")) =~ "# new"
    assert File.read!(Path.join(Autopoet.Body.root(), "journal.work")) =~ "appended line"
  end
end
