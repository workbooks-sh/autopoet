defmodule Autopoet.BusinessLoopEvalTest do
  @moduledoc """
  v3 foundations (wb-siutv) — the autonomous business loop's boundaries, proven
  with injected transports (no live analytics/spend/LLM needed; identical code
  runs live). Three gates:

    T (Treasury) — the money wall: fail-safe (spends nothing until funded),
      caps refuse, revenue funds runway, reboot-safe.
    M (Market)   — the oracle: external signals settle as reward (ledger) +
      revenue (treasury); no LLM opinion enters.
    S (SimHuman) — the scoped proxy: structurally cannot settle reward; the
      Goodhart reconcile catches a sim that drifts from the market.
  """
  use ExUnit.Case, async: false

  alias Autopoet.{Market, SimHuman, Treasury}

  setup do
    # each test starts from the fail-safe zero state (balance/spend carry across
    # calls otherwise) and restores it after
    Treasury.reset()
    on_exit(fn -> Treasury.reset() end)
    :ok
  end

  test "T-FAILSAFE: out of the box the treasury spends NOTHING (cap 0, enforced)" do
    Treasury.fund(0.0, 0.0)
    assert {:error, :over_total_cap} = Treasury.charge(0.01, "domain", "site")
    s = Treasury.status()
    assert s.enforce and s.cap_total == 0.0
    IO.puts("  ✓ EVAL business/failsafe — unfunded treasury refuses every spend")
  end

  test "T-CAPS: caps refuse; revenue funds runway; charge debits" do
    Treasury.fund(20.0, 5.0)

    # a human funded $20 total / $5 daily — but there's no runway yet
    assert {:error, :insufficient_runway} = Treasury.charge(3.0, "hosting", "site")

    # the market earns $10 → runway exists
    assert {:ok, 10.0} = Treasury.earn(10.0, :market)
    assert {:ok, bal} = Treasury.charge(3.0, "hosting", "site")
    assert bal == 7.0

    # daily cap bites before the total cap
    assert {:error, :over_daily_cap} = Treasury.charge(3.0, "ads", "site")

    s = Treasury.status()
    assert s.spent_today == 3.0 and s.earned_total == 10.0
    IO.puts("  ✓ EVAL business/treasury — caps refuse, revenue funds runway, spend debits (runway $#{s.runway})")
  end

  test "T-REBOOT: treasury balance + caps survive a restart" do
    Treasury.fund(50.0, 50.0)
    Treasury.earn(30.0, :market)
    Treasury.charge(12.0, "domain", "site")
    :ok = Treasury.snapshot()

    GenServer.stop(Treasury)
    Process.sleep(200)

    s = Treasury.status()
    assert s.balance == 18.0 and s.earned_total == 30.0 and s.cap_total == 50.0
    IO.puts("  ✓ EVAL business/treasury-reboot — runway $#{s.balance} survived restart")
  end

  test "M-ORACLE: market signals settle as reward AND revenue; the market is the judge" do
    Treasury.fund(100.0, 100.0)
    before_rewards = Autopoet.Shadow.Outcomes.stats().rewards
    before_runway = Treasury.status().balance

    tally =
      Market.ingest([
        %{kind: :view, target: "gapfinder", value: 40},
        %{kind: :signup, target: "gapfinder", value: 3},
        %{kind: :revenue, target: "gapfinder", value: 29.0}
      ])

    assert tally.views == 40 and tally.signups == 3 and tally.revenue_usd == 29.0
    Process.sleep(300)

    # reward landed in the ledger (the learning signal)
    assert Autopoet.Shadow.Outcomes.stats().rewards.count > before_rewards.count
    ledger = Autopoet.Shadow.Outcomes.ledger().rewards["gapfinder"]
    assert ledger.count >= 3

    # revenue funded the runway (the treasury)
    assert Treasury.status().balance == Float.round(before_runway + 29.0, 4)

    IO.puts("  ✓ EVAL business/market — 40 views/3 signups/$29 → ledger reward + $29 runway (market is the oracle)")
  end

  test "S-NOREWARD: the sim-human CANNOT settle reward — structural, not incidental" do
    # the whole module surface returns opinions; none of it touches the ledger
    before = Autopoet.Shadow.Outcomes.stats().rewards.count

    cust = SimHuman.customer("Buy my widget! Only $9.", "skeptical bargain-hunter", complete: fn _ -> {:ok, "INTEREST: 0.8\nSIGNUP: yes\nWHY: cheap enough to try"} end)
    scr = SimHuman.screen("Add a pricing page with three tiers", complete: fn _ -> {:ok, "VERDICT: accept\nNOTE: pricing clarity converts"} end)

    Process.sleep(200)
    assert Autopoet.Shadow.Outcomes.stats().rewards.count == before, "S-NOREWARD FAILED: a sim opinion moved the reward ledger"
    assert cust.sim and scr.sim
    assert cust.would_signup and scr.suggest == :accept

    IO.puts("  ✓ EVAL business/sim-noreward — customer + screen return opinions; ledger untouched (Sakana trap avoided)")
  end

  test "S-GOODHART: the reconcile catches a sim that loves what the market ignores" do
    # a drifted sim: says signup every time, market rewards almost none
    drifted =
      for _ <- 1..8, do: {%{would_signup: true, sim: true}, false}

    recon = SimHuman.reconcile(drifted)
    assert recon.sim_optimism_gap == 1.0
    assert SimHuman.alarm?(recon), "the tripwire should fire on a sim that's always-yes vs an unmoved market"

    # a faithful sim: predictions track reality
    faithful = [
      {%{would_signup: true}, true},
      {%{would_signup: false}, false},
      {%{would_signup: true}, true},
      {%{would_signup: false}, false},
      {%{would_signup: false}, false}
    ]

    recon2 = SimHuman.reconcile(faithful)
    refute SimHuman.alarm?(recon2)

    IO.puts("  ✓ EVAL business/goodhart — drifted sim alarms (gap #{recon.sim_optimism_gap}); faithful sim silent")
  end

  test "S-ANTICOLLUSION: the sim uses a model distinct from the brain's agent model" do
    sim = Application.get_env(:autopoet, :sim_model, "meta-llama/llama-3.3-70b-instruct")
    brain = Autopoet.Providers.agent_model()
    refute sim == brain, "S-ANTICOLLUSION: sim-human must not share the brain's model (it would grade its own writing)"
    IO.puts("  ✓ EVAL business/anti-collusion — sim model #{sim} ≠ brain agent #{brain}")
  end
end
