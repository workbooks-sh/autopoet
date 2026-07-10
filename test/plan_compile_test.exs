defmodule Autopoet.PlanCompileTest do
  use ExUnit.Case, async: false

  # the onboarding-finalize regressions (2026-07-10): a payload-shape drift sent
  # deck/pairing/form as nil — from_deck raised in fallback/2 (Map.get on nil),
  # the route 500'd silently, and the owner heard "your environment is set up"
  # over a vault that never built.

  test "from_deck survives nil everything — deterministic fallback, no raise" do
    assert {:ok, plan} = Autopoet.PlanCompile.from_deck(nil, nil, nil)
    assert plan.title != ""
    assert plan.pages != []
    assert [%{name: _, job: _} | _] = plan.agents
  end

  test "from_deck with a blank deck skips the LLM and still yields a whole plan" do
    form = %{"name" => "Shane Murphy", "areas" => ["business"]}
    assert {:ok, plan} = Autopoet.PlanCompile.from_deck("", %{}, form)
    assert plan.title != ""
    assert plan.firstrun != ""
    # the profile carries the contract Intake.parse_plan reads back
    profile = Autopoet.Profile.all()
    assert (profile["plan.workspace"] || "") =~ plan.title
    assert profile["owner"] == "Shane Murphy"
    assert profile["intent"] == "money"
  end

  test "from_deck with a real deck derives pages from its headings (no-LLM lane)" do
    deck = """
    # Studio Plan

    - the vision
    ---
    # Orders Desk

    - watch orders
    ---
    # Money Watch

    - reconcile nightly
    """

    assert {:ok, plan} = Autopoet.PlanCompile.from_deck(deck, %{}, %{"name" => "Shane"})
    assert plan.title == "Studio Plan"
    assert "Orders Desk" in plan.pages
    assert "Money Watch" in plan.pages
  end
end
