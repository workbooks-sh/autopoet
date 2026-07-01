defmodule Autopoet.AvatarTest do
  use ExUnit.Case

  test "composition is deterministic per seed and glasses-free" do
    a = Autopoet.Avatar.svg("autopoet-1")
    b = Autopoet.Avatar.svg("autopoet-1")
    c = Autopoet.Avatar.svg("different-seed")

    assert a == b
    refute a == c

    # all four composed groups present, at the style's verbatim transforms
    for t <- ["translate(136 328)", "translate(246 125)", "translate(-45 137)", "translate(119 114)"] do
      assert String.contains?(a, t)
    end

    # glasses share eyes' transform — exactly one group at that transform means none
    assert length(String.split(a, "translate(-45 137)")) == 2
  end

  test "the full vendored part library is present and categorized" do
    assert length(Autopoet.Avatar.variants("lips")) == 30
    assert length(Autopoet.Avatar.variants("nose")) == 20
    assert length(Autopoet.Avatar.variants("eyes")) == 5
    assert length(Autopoet.Avatar.variants("brows")) == 13
    # glasses vendored + categorized for future curation, just not composed
    assert length(Autopoet.Avatar.variants("glasses")) == 11
  end
end
