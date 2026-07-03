defmodule Autopoet.IntakeTest do
  use ExUnit.Case, async: true

  # the shopify persona — the bootstrap-planner exemplar, as quiz output lines
  @profile %{
    "intent" => "money",
    "money_road" => "sell",
    "industry" => "performance-creative (performance creative)",
    "speak" => "none",
    "leash" => "fenced",
    "git.notes" => "i also use nix, worth knowing",
    "plan.workspace" => "shop — orders, listings, money watch",
    "plan.agent.1" => "shopkeeper — watches orders and stock, drafts listings",
    "plan.agent.2" => "bookkeeper — reconciles payouts against orders nightly",
    "plan.rule.1" => "when an order lands, log it and update today's tally",
    "plan.rule.2" => "when an email needs a reply, draft one in my voice",
    "plan.connect" => "shopify, stripe, gmail",
    "plan.setting" => "leash=fenced pings=digest oops=revert voice=short",
    "plan.firstrun" => "the bookkeeper reconciles sample numbers onto money watch — live, on load"
  }

  test "plan parsing extracts the full contract" do
    plan = Autopoet.Intake.parse_plan(@profile)
    assert plan.workspace.name == "shop"
    assert plan.workspace.pages == ["orders", "listings", "money watch"]
    assert [%{slug: "shopkeeper"}, %{slug: "bookkeeper"}] = plan.agents
    assert length(plan.rules) == 2
    assert plan.connect == ["shopify", "stripe", "gmail"]
    assert plan.firstrun =~ "reconciles sample numbers"
  end

  test "skeleton emits agent blocks the Literate parser registers" do
    plan = Autopoet.Intake.parse_plan(@profile)
    files = Autopoet.Intake.skeleton(@profile, plan)

    agents_src = files["shop/agents.work"]
    nodes = Nexus.Literate.parse(agents_src)
    agent_nodes = Enum.filter(nodes, &(&1.type == :code and &1.kind == "agent"))
    assert length(agent_nodes) == 2
    # policy from the human's answers is baked into every charter
    assert agents_src =~ "leash=fenced pings=digest oops=revert"
  end

  test "skeleton carries the human's notes verbatim and stages rules inert" do
    plan = Autopoet.Intake.parse_plan(@profile)
    files = Autopoet.Intake.skeleton(@profile, plan)

    assert files["intake/briefing.work"] =~ "i also use nix, worth knowing"
    assert files["shop/rules.work"] =~ "#proposed"
    assert files["shop/rules.work"] =~ "when an order lands"
    # one page file per plan.workspace page
    for page <- ["orders", "listings", "money-watch"] do
      assert Map.has_key?(files, "shop/#{page}.work")
    end

    assert files["intake/firstrun.work"] =~ "ignition"
  end

  test "the empty profile still yields a complete quiet world" do
    plan = Autopoet.Intake.parse_plan(%{})
    files = Autopoet.Intake.skeleton(%{}, plan)
    assert plan.workspace.name == "notebook"
    assert Map.has_key?(files, "notebook/index.work")
    assert files["notebook/rules.work"] =~ "rules"
  end

  test "the brief proposes, never dictates" do
    plan = Autopoet.Intake.parse_plan(@profile)
    brief = Autopoet.Intake.brief(@profile, plan)
    assert brief =~ "accept this proposal"
    assert brief =~ "shopkeeper"
    assert brief =~ "start with shopify"
    assert brief =~ "undoable"
  end

  test "the scout is consent-scoped: scan lines in, picks out, nothing unpicked" do
    plan = Autopoet.Intake.parse_plan(@profile)
    files = Autopoet.Intake.skeleton(@profile, plan)
    scout = files["intake/scout.work"]
    nodes = Nexus.Literate.parse(scout)
    assert Enum.any?(nodes, &(&1.type == :code and &1.kind == "agent"))
    assert scout =~ "grant net"
    assert scout =~ "Never fetch anything not named"

    assert Autopoet.Intake.scans(%{"scan.github" => "org/repo-a, org/repo-b", "scan.cloudflare" => ""}) ==
             [{"github", ["org/repo-a", "org/repo-b"]}]
  end
end
