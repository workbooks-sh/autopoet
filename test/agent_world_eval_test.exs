defmodule Autopoet.AgentWorldEvalTest do
  @moduledoc """
  EVAL SUITE — can the agent actually work with the whole world?

  Proves, deterministically (no LLM/network), the two capability planes:

    * READ  — the agent reaches EVERYTHING through one skill: the sandboxed shell
      (`Autopoet.VoiceTools.shell`, read-only) over the `/work` mount. It ls/cat/
      greps the body (/work/nexus), the human's notes (/work/notes), the OOTA
      recipe library (/work/oota), and deep-searches subdirectories.

    * WRITE/EDIT — the agent NEVER writes /work directly (the shell is read-only);
      it mutates the body through the gated proposal flow (record → accept →
      applied), which is exactly how the brain edits. The write is then visible
      to the agent's shell — proving the two planes share one world. Append
      extends a file; revert restores it.

  Run it as a scorecard:  `mix test test/agent_world_eval_test.exs`
  """
  use ExUnit.Case, async: false

  # Runtime accessors (test env WB_DATA differs from dev): the shell sees `world/`,
  # the brain writes the body at `body()` — which MUST live under `world` so the
  # agent can read what the brain writes.
  defp home, do: Autopoet.Discovery.home()
  defp world, do: Path.join(home(), "data")
  # the body lives at world/nexus — exactly what the shell reads as /work/nexus, and
  # where the running app's Nexus.Paths.data_dir() resolves (WB_DATA=<home>/data/nexus).
  defp body, do: Path.join(world(), "nexus")
  defp shell_path(rel), do: Path.join("/work/nexus", rel)

  setup do
    File.mkdir_p!(Path.join(body(), "sub"))
    File.mkdir_p!(Path.join(world(), "notes"))
    File.write!(Path.join(body(), "eval_seed.work"), "# Eval Seed\n\nmarker: KESTREL is here.\n")
    File.write!(Path.join(body(), "sub/deep_seed.work"), "nested marker: FALCON in a subdir.\n")
    File.write!(Path.join(world(), "notes/eval_note.md"), "a human note mentioning KESTREL.\n")

    on_exit(fn ->
      File.rm(Path.join(body(), "eval_seed.work"))
      File.rm_rf(Path.join(body(), "sub"))
      File.rm(Path.join(world(), "notes/eval_note.md"))
    end)

    :ok
  end

  # ── READ plane: one skill (the shell) sees the whole world ────────────────

  test "READ: the agent cats a body doc through the sandboxed shell" do
    {out, ok} = Autopoet.VoiceTools.shell("cat #{shell_path("eval_seed.work")}")
    assert ok
    assert out =~ "KESTREL is here", "the brain's body is not agent-readable at #{shell_path("eval_seed.work")}"
    score("READ: body doc content readable via the shell")
  end

  test "READ: the agent reads the human's notes (source of truth)" do
    {out, ok} = Autopoet.VoiceTools.shell("cat /work/notes/eval_note.md")
    assert ok
    assert out =~ "KESTREL"
    score("READ: the vault (human notes) is readable")
  end

  test "SEARCH: deep grep -r finds content in nested body subdirs" do
    {out, ok} = Autopoet.VoiceTools.shell("grep -ri falcon #{shell_path("")}")
    assert ok
    assert out =~ "deep_seed.work", "deep subdir recursion missing (fd_readdir d_ino rider)"
    assert out =~ "FALCON in a subdir"
    score("SEARCH: recursive grep reaches nested subdirectories")
  end

  test "SEARCH: one grep spans body + notes" do
    {out, ok} = Autopoet.VoiceTools.shell("grep -rli kestrel #{shell_path("")} /work/notes")
    assert ok
    assert out =~ "eval_seed.work"
    assert out =~ "eval_note.md"
    score("SEARCH: one query spans multiple world areas")
  end

  test "READ: the OOTA recipe library is readable in-sandbox (when seeded)" do
    Autopoet.Oota.seed_reference()

    if File.dir?(Autopoet.Oota.dest()) do
      {out, ok} = Autopoet.VoiceTools.shell("ls /work/oota")
      assert ok
      assert out =~ "tools" or out =~ "docs"
      score("READ: the OOTA recipe library is browsable at /work/oota")
    else
      score("READ: OOTA library SKIPPED (not seeded in this env)")
    end
  end

  # ── SANDBOX SAFETY: the read skill cannot write ──────────────────────────

  test "SAFETY: the agent shell is read-only — no writes, no redirects" do
    {out, ok} = Autopoet.VoiceTools.shell("echo pwned > #{shell_path("eval_seed.work")}")
    assert ok == false or out =~ "read-only"
    assert File.read!(Path.join(body(), "eval_seed.work")) =~ "KESTREL is here"
    score("SAFETY: the read skill refuses writes (redirects blocked)")
  end

  # ── WRITE plane A: the agent authors its BODY (.work) DIRECTLY ────────────
  # The body is the agent's own structure — immediate write, no proposal, undoable.

  test "WRITE: the agent writes a NEW body file directly, then reads it back" do
    {:ok, hid} = Autopoet.Body.write("eval_written.work", "# Direct\nmarker: OSPREY.\n")
    assert is_binary(hid)

    {out, ok} = Autopoet.VoiceTools.shell("cat #{shell_path("eval_written.work")}")
    assert ok
    assert out =~ "OSPREY", "the direct write is not visible to the agent shell"

    File.rm(Path.join(body(), "eval_written.work"))
    score("WRITE: agent writes .work directly (no proposal), agent-readable")
  end

  test "EDIT: a direct append extends a body file without clobbering it" do
    base = Path.join(body(), "eval_edit.work")
    File.write!(base, "line one\n")

    {:ok, _hid} = Autopoet.Body.apply(%{}, %{"eval_edit.work" => "line two APPENDED"})
    {out, ok} = Autopoet.VoiceTools.shell("cat #{shell_path("eval_edit.work")}")
    assert ok
    assert out =~ "line one" and out =~ "line two APPENDED"

    File.rm(base)
    score("EDIT: direct append extends a file without clobbering it")
  end

  test "UNDO: any direct body write is recoverable from history" do
    base = Path.join(body(), "eval_undo.work")
    File.write!(base, "ORIGINAL\n")

    {:ok, hid} = Autopoet.Body.write("eval_undo.work", "REPLACED\n")
    assert File.read!(base) =~ "REPLACED"

    assert :ok = Autopoet.Body.undo(hid)
    assert File.read!(base) =~ "ORIGINAL", "undo did not restore the pre-write snapshot"

    File.rm(base)
    score("UNDO: a direct write is reversible from history")
  end

  test "UNDO: undoing a NEW-file write removes the file (absent restore)" do
    {:ok, hid} = Autopoet.Body.write("eval_new.work", "brand new\n")
    assert File.exists?(Path.join(body(), "eval_new.work"))
    assert :ok = Autopoet.Body.undo(hid)
    refute File.exists?(Path.join(body(), "eval_new.work")), "undo did not remove the newly-created file"
    score("UNDO: undoing a new file removes it (absent list)")
  end

  # ── WRITE plane B: the VAULT is the human's — the agent can only SUGGEST ───
  # A proposal now targets a NOTE (the source of truth); the human gates it.

  test "PROPOSE: the agent suggests a VAULT edit; accept applies it to the human's note" do
    File.mkdir_p!(Path.join(world(), "notes"))
    File.write!(Path.join(world(), "notes/suggest_me.md"), "old line\n")

    id =
      Autopoet.Proposals.record(
        %{target: "notes/suggest_me.md"},
        %{"suggest_me.md" => "old line\nSUGGESTED by the agent\n"}
      )

    assert Enum.any?(Autopoet.Proposals.pending(), fn {pid, _} -> pid == id end)
    # accepting applies to the VAULT (the human's gate); revert restores
    assert :ok = Autopoet.Proposals.accept(id, Autopoet.Notes.dir())
    assert File.read!(Path.join(Autopoet.Notes.dir(), "suggest_me.md")) =~ "SUGGESTED by the agent"

    assert :ok = Autopoet.Proposals.revert(id, Autopoet.Notes.dir())
    assert File.read!(Path.join(Autopoet.Notes.dir(), "suggest_me.md")) == "old line\n"

    File.rm(Path.join(world(), "notes/suggest_me.md"))
    score("PROPOSE: vault edits are suggestion-only (gated + reversible)")
  end

  defp score(msg), do: IO.puts("  ✓ EVAL — " <> msg)
end
