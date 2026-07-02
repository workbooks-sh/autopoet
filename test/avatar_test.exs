defmodule Autopoet.AvatarTest do
  use ExUnit.Case

  test "the face is minimal (eyes + mouth only) — no skin/hair/ears/background" do
    a = Autopoet.Avatar.svg()
    assert a =~ ~s(id="ap-eyes")
    assert a =~ ~s(id="ap-mouth")
    assert a =~ ~s(id="ap-face")
    assert a =~ ~s(id="ap-eyes-px")          # parallax depth wrapper
    # nothing colored/identity: no tokens, no background rect, no hair layer
    refute a =~ "SKINCOLOR"
    refute a =~ "HAIRCOLOR"
    refute a =~ "<rect"
  end

  test "all 7 dylan moods are available as swappable mouths" do
    m = Autopoet.Avatar.mouths()
    for mood <- ~w(neutral happy superHappy sad angry hopeful confused) do
      assert is_binary(m[mood]) and m[mood] =~ "<path"
    end
  end
end
