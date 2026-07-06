defmodule Autopoet.WorldGraphTest do
  use ExUnit.Case

  test "the world graph centers the self, includes docs/agents, and every link resolves" do
    %{nodes: nodes, links: links} = Autopoet.WorldGraph.payload()
    ids = MapSet.new(nodes, & &1.id)

    assert "self" in ids
    assert Enum.any?(nodes, &(&1.type == "doc"))
    assert Enum.any?(nodes, &(&1.type == "agent"))
    assert Enum.all?(nodes, &is_binary(&1.detail))

    for l <- links do
      assert MapSet.member?(ids, l.source), "dangling source #{l.source}"
      assert MapSet.member?(ids, l.target), "dangling target #{l.target}"
    end

    # the payload is a genuine HTTP boundary — it must encode
    assert {:ok, _} = Jason.encode(%{nodes: nodes, links: links}) |> then(&{elem(&1, 0), nil})
  end
end
