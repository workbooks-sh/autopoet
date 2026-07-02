defmodule Autopoet.ChatTest do
  use ExUnit.Case, async: false

  test "sessions: new → send (seamed llm) → transcript → list; multi-line rides one block" do
    Application.put_env(:autopoet, :chat_llm, fn messages ->
      # the system prompt heads the conversation and carries world context
      assert [%{role: "system", content: sys} | turns] = messages
      assert sys =~ "NEVER edit"
      assert List.last(turns).content =~ "what is pending"
      {:ok, "nothing urgent.\ncheck [[todos]]."}
    end)

    id = Autopoet.Chat.new()
    assert {:ok, reply} = Autopoet.Chat.send(id, "what is pending?\nanything?")
    assert reply =~ "[[todos]]"

    {:ok, t} = Autopoet.Chat.transcript(id)
    assert t =~ "[user] what is pending? ⏎ anything?"
    assert t =~ "[autopoet] nothing urgent. ⏎ check [[todos]]."

    assert Enum.any?(Autopoet.Chat.sessions(), &(&1.id == id and &1.preview =~ "what is pending"))
  after
    Application.delete_env(:autopoet, :chat_llm)
  end

  test "unsafe chat ids are refused" do
    assert_raise ArgumentError, fn -> Autopoet.Chat.send("../evil", "hi") end
  end
end
