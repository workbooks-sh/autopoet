defmodule Autopoet.LimbsTest do
  use ExUnit.Case

  test "the research limb is seeded into the body and registered with a narrowed grant" do
    names = Autopoet.Limbs.register_from_body() |> Enum.map(&to_string/1)
    assert "research_limb" in names

    node = Nexus.Agent.get(:research_limb) || Nexus.Agent.get("research_limb")
    assert node != nil

    d = Nexus.Agent.def_from_unit(node)
    # grant is net ONLY — the limb browses; it holds nothing else
    assert Enum.map(List.wrap(d[:grant]), &to_string/1) == ["net"]
    # frozen: the autopoet can never autonomously edit its own limb's structure
    assert to_string(Nexus.Agent.management(node)) == "frozen"
    # non-negotiable #3: limits do not exist — limbs declare none (fail-mode ceiling only)
    assert d[:limit] in [nil, []]
  end

  test "oota is a LIBRARY the sandbox reads — never a host process" do
    # canon: no native execution — the old host-exec verb must not exist
    refute function_exported?(Autopoet.Oota, :run, 1)

    # point at a tiny FIXTURE project (not the real 2GB one) so the test is isolated + fast
    fixture = Path.join(System.tmp_dir!(), "oota-fix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(fixture, "tools/steps"))
    File.mkdir_p!(Path.join(fixture, "cli/node_modules/junk"))
    File.write!(Path.join(fixture, "tools/steps/diagrams-mermaid.sh"), "#recipe: mermaid\n")
    File.write!(Path.join(fixture, "cli/node_modules/junk/big.bin"), "should NOT be mirrored")
    System.put_env("AUTOPOET_OOTA_DIR", fixture)
    on_exit(fn -> System.delete_env("AUTOPOET_OOTA_DIR"); File.rm_rf(fixture) end)

    assert :ok = Autopoet.Oota.seed_reference()
    # the recipe lands in the world; the 2GB cli/node_modules never rides along
    assert File.exists?(Path.join(Autopoet.Oota.dest(), "tools/steps/diagrams-mermaid.sh"))
    refute File.dir?(Path.join(Autopoet.Oota.dest(), "cli"))

    # and it's readable through the SANDBOXED shell at /work/oota (the real access path)
    {out, ok} = Autopoet.VoiceTools.shell("grep -rli mermaid /work/oota/tools")
    assert ok
    assert out =~ "diagrams-mermaid.sh"
  end
end
