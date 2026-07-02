defmodule Autopoet.RevertTest do
  use ExUnit.Case

  test "accept snapshots replaced/created files; revert restores the exact prior state" do
    root = Path.join(Autopoet.Discovery.home(), "revert_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "index.work"), "# original index\n")

    id =
      Autopoet.Proposals.record(%{target: "x", kind: :request}, %{
        "existing.work" => "# replaced\n",
        "brand-new.work" => "# created\n"
      })

    File.write!(Path.join(root, "existing.work"), "# the original\n")

    assert :ok = Autopoet.Proposals.accept(id, root)
    assert File.read!(Path.join(root, "existing.work")) == "# replaced\n"
    assert File.exists?(Path.join(root, "brand-new.work"))

    assert :ok = Autopoet.Proposals.revert(id, root)
    assert File.read!(Path.join(root, "existing.work")) == "# the original\n"
    refute File.exists?(Path.join(root, "brand-new.work"))
    assert Autopoet.Proposals.status(id) == "reverted"

    # revert is once-only
    assert {:error, _} = Autopoet.Proposals.revert(id, root)
  end
end
