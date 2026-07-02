defmodule Autopoet.AvatarTest do
  use ExUnit.Case

  test "composition is deterministic per seed, layered, and eyes are fixed/blinkable" do
    a = Autopoet.Avatar.svg("autopoet-1")
    assert a == Autopoet.Avatar.svg("autopoet-1")
    refute a == Autopoet.Avatar.svg("someone-else")

    # animatable layers present
    assert a =~ ~s(id="ap-eyes")
    assert a =~ ~s(id="ap-mouth")
    # color tokens fully resolved (no leftover placeholders)
    refute a =~ "SKINCOLOR"
    refute a =~ "HAIRCOLOR"
  end

  test "all 7 dylan moods are available as swappable mouths" do
    m = Autopoet.Avatar.mouths()
    for mood <- ~w(neutral happy superHappy sad angry hopeful confused) do
      assert is_binary(m[mood]) and m[mood] =~ "<path"
    end
  end
end
