defmodule Autopoet.GuideTest do
  use ExUnit.Case

  test "guide is seeded into the body, indexed one line per page, reads sanitized" do
    assert "anatomy" in Autopoet.Guide.pages()
    assert "autopoet-rules" in Autopoet.Guide.pages()
    assert Autopoet.Guide.index() =~ "block-grammar"
    assert Autopoet.Guide.read("block-grammar") =~ "block"
    assert Autopoet.Guide.read("../../../etc/passwd") == nil
  end

  test "planner progressive disclosure: NEED loads pages into a second round, drafter rides along" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    Application.put_env(:autopoet, :brain_llm, fn prompt ->
      Agent.update(calls, &(&1 ++ [prompt]))

      case length(Agent.get(calls, & &1)) do
        1 -> {:ok, "NEED: block-grammar\nNEED: autopoet-rules"}
        2 -> {:ok, "Plan: append one line to journal.work"}
        _ -> {:ok, "=== file: journal.work ===\n# Journal\n\na disclosed line\n"}
      end
    end)

    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    assert {:ok, changes} = Autopoet.Brain.propose(%{target: "journal", change: "test disclosure"})
    assert map_size(changes) == 1

    [p1, p2, p3] = Agent.get(calls, & &1)
    # round 1 carries the protocol + the index, not the pages
    assert p1 =~ "NEED: <page>"
    refute p1 =~ "--- guide: block-grammar ---"
    # round 2 carries the requested pages
    assert p2 =~ "--- guide: block-grammar ---"
    assert p2 =~ "--- guide: autopoet-rules ---"
    # the draft rides on the plan AND the consulted pages
    assert p3 =~ "Plan: append one line"
    assert p3 =~ "--- guide: block-grammar ---"
  end

  test "a plan without NEED lines goes straight to drafting (two calls total)" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    Application.put_env(:autopoet, :brain_llm, fn prompt ->
      Agent.update(calls, &(&1 ++ [prompt]))

      case length(Agent.get(calls, & &1)) do
        1 -> {:ok, "Plan: tiny append, no guide needed"}
        _ -> {:ok, "=== file: journal.work ===\n# Journal\n\nplain\n"}
      end
    end)

    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    assert {:ok, _} = Autopoet.Brain.propose(%{target: "journal", change: "no disclosure"})
    assert length(Agent.get(calls, & &1)) == 2
  end
end
