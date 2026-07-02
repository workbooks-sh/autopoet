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

  test "oota is host-side and degrades cleanly when unavailable" do
    case Autopoet.Oota.available?() do
      true -> assert {:ok, out} = Autopoet.Oota.run(["help"]) |> then(fn r -> r end)
      false -> assert {:error, :oota_unavailable} = Autopoet.Oota.run(["help"])
    end
  end
end
