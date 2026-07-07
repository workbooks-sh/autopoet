defmodule Autopoet.WorldGraphTest do
  use ExUnit.Case

  # The graph reads the live body (`Nexus.Paths.data_dir/0`). A genesis-CLEAN body has
  # only the self + seeded agents and NO plain docs, so seed one `.work` doc here rather
  # than depend on state another test/run happened to leave behind (the state-coupling
  # that made this pass on an accumulated home and fail on a fresh one).
  setup do
    doc = Path.join(Nexus.Paths.data_dir(), "eval_graph_doc.work")
    File.mkdir_p!(Path.dirname(doc))
    File.write!(doc, "# Eval Graph Doc\n\nA plain body doc so the graph has a `doc` node.\n")

    # a NON-system agent, so the graph has an `agent`-typed node — the boot-seeded
    # `researcher`/`intake_scout` are `@system_agents` and render as type "system".
    "agent :graph_helper do\n  prompt \"help\"\n  model \"x\"\n  grant net\nend"
    |> Nexus.Literate.parse()
    |> Enum.find(&(&1[:kind] == "agent"))
    |> Nexus.Agent.register()

    on_exit(fn -> File.rm(doc) end)
    :ok
  end

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
