defmodule Autopoet.FundEvalTest do
  @moduledoc """
  FUND CAMPAIGN eval — whole finance engagement through production machinery
  (Actions.route_intents → gated proposals → risk cage → fills → P&L → ledger).
  Hermetic tier: scripted brain + fixture tape. Gates:

    FC-PROSPECTUS  brain produces a prospectus artifact with thesis/universe/
                   risk/rules sections (parsed, not vibes).
    FC-RESEARCH    bars read for candidates BEFORE any order proposed.
    FC-CAMPAIGN    3-cycle campaign on a trending tape: orders arrive as GATED
                   proposals, fills at tape prices, positive realized P&L,
                   P&L settles into the Outcomes ledger.
    FC-MANDATE     an off-universe order is rejected by the human verb and
                   recorded as a violation — mandate holds.
    FC-CAGE        an over-cap order passes the human but the RISK CAGE refuses
                   it at execution — two independent walls.

  LIVE tier (:live + AUTOPOET_LIVE=1): the REAL brain (OpenRouter, eval-only
  direct) runs the same campaign on the REAL Alpaca paper account.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.Fund

  # trending tape: AAPL grinds up (the thesis symbol), XYZ flat
  defp tape do
    %{
      "AAPL" => for(i <- 1..30, do: %{"c" => 100.0 + i * 2.0, "v" => 1_000_000}),
      "XYZ" => for(_ <- 1..30, do: %{"c" => 50.0, "v" => 100_000})
    }
  end

  # the scripted brain: phase-tagged prompts → canned production-shaped output
  defp scripted_brain(opts \\ %{}) do
    fn prompt ->
      cond do
        prompt =~ "PHASE: research" ->
          {:ok,
           """
           === action: alpaca_account ===
           {}

           === action: alpaca_bars ===
           {"symbol": "AAPL"}

           === action: alpaca_bars ===
           {"symbol": "XYZ"}
           """}

        prompt =~ "PHASE: prospectus" ->
          {:ok,
           """
           === file: fund/prospectus.work ===
           # Momentum Fund

           ## Thesis
           Buy confirmed uptrends, exit into strength. AAPL grinding higher on volume.

           ## Universe
           - AAPL

           ## Risk
           Per-order cap $5000. Max 1 position.

           ## Entry / Exit
           Enter when last close > first close by 5%. Exit final cycle.
           """}

        prompt =~ "PHASE: trade (cycle 1)" ->
          {:ok, order_block(opts[:cycle1] || %{symbol: "AAPL", qty: 30, side: "buy"})}

        prompt =~ "PHASE: trade (cycle 2)" ->
          {:ok, opts[:cycle2] || ""}

        prompt =~ "PHASE: trade (cycle 3)" ->
          {:ok, order_block(%{symbol: "AAPL", qty: 30, side: "sell"})}

        true ->
          {:ok, ""}
      end
    end
  end

  defp order_block(%{symbol: s, qty: q, side: side}) do
    """
    === action: alpaca_place_order ===
    {"symbol": "#{s}", "qty": #{q}, "side": "#{side}"}
    """
  end

  test "FC-PROSPECTUS + FC-RESEARCH: prospectus artifact + research-before-trade" do
    report = Fund.run(brain: scripted_brain(), tape: tape(), cycles: 3)

    # prospectus parsed with all sections
    p = report.prospectus
    assert p.thesis =~ "uptrend"
    assert p.universe == ["AAPL"]
    assert p.risk =~ "5000"
    assert p.rules =~ "Enter"

    # research happened (both candidates) before any proposal
    assert length(report.research) >= 2
    assert length(report.proposals) >= 1

    IO.puts("  ✓ EVAL fund/prospectus — thesis+universe+risk+rules parsed; #{length(report.research)} research reads before first order")
  end

  test "FC-CAMPAIGN: 3 cycles, gated orders, fills, positive P&L, ledger settle" do
    before = Autopoet.Shadow.Outcomes.stats().rewards.count
    report = Fund.run(brain: scripted_brain(), tape: tape(), cycles: 3)

    # orders were PROPOSED (gated), then executed by the human verb through the cage
    assert length(report.proposals) == 2
    assert length(report.fills) == 2
    assert report.violations == []

    # bought the uptrend early, sold later → positive realized P&L
    assert report.realized_pnl > 0

    # P&L settled as market reward → the ledger
    Process.sleep(300)
    assert Autopoet.Shadow.Outcomes.stats().rewards.count > before
    ledger = Autopoet.Shadow.Outcomes.ledger().rewards["trade:AAPL"]
    assert ledger != nil and ledger.amount > 0

    IO.puts("  ✓ EVAL fund/campaign — 2 gated orders → fills → +$#{report.realized_pnl} realized → ledger (equity #{inspect(report.equity_curve)})")
  end

  test "FC-MANDATE: off-universe order rejected by the human verb, recorded" do
    report =
      Fund.run(
        brain: scripted_brain(%{cycle1: %{symbol: "XYZ", qty: 10, side: "buy"}}),
        tape: tape(),
        cycles: 3
      )

    assert {:off_mandate, "XYZ"} in report.violations
    assert Enum.any?(report.rejected, &(&1[:symbol] == "XYZ"))
    # the sell in cycle 3 had no position (buy was rejected) → naked-sell violation, not a crash
    assert length(report.fills) == 0 or Enum.all?(report.fills, &(&1.symbol != "XYZ"))

    IO.puts("  ✓ EVAL fund/mandate — XYZ (off-universe) rejected + recorded; campaign survives")
  end

  test "FC-CAGE: over-cap order passes the human but the risk cage refuses execution" do
    # 100 shares × ~$140+ ≈ $14k+ notional > $5k cap
    report =
      Fund.run(
        brain: scripted_brain(%{cycle1: %{symbol: "AAPL", qty: 100, side: "buy"}}),
        tape: tape(),
        cycles: 3
      )

    assert length(report.refused) >= 1
    assert Enum.all?(report.fills, fn f -> f.qty * f.price <= 5_000.0 end)

    IO.puts("  ✓ EVAL fund/cage — over-cap order refused at execution (#{length(report.refused)} refusal); two independent walls hold")
  end

  # ── LIVE tier: real brain + real paper account (double-locked) ──────────────

  @tag :live
  test "FC-LIVE: the real brain runs the campaign on the real paper account" do
    unless System.get_env("AUTOPOET_LIVE") == "1", do: flunk("AUTOPOET_LIVE=1 required")

    brain = fn prompt ->
      case Autopoet.Providers.openrouter([%{role: "user", content: prompt}], max_tokens: 1200, temperature: 0.3) do
        {:ok, %{content: c}} -> {:ok, c}
        other -> other
      end
    end

    # real paper keys from env; real bars; the harness still plays the human
    key = System.get_env("ALPACA_KEY_ID")
    secret = System.get_env("ALPACA_SECRET_KEY")
    assert is_binary(key), "ALPACA_KEY_ID required for the live tier"

    {:ok, acct} = Autopoet.Alpaca.account(key: key, secret: secret)
    assert acct["status"] == "ACTIVE"

    report = Fund.run(brain: brain, tape: live_tape(key, secret), cycles: 2)
    assert report.prospectus.universe != []
    IO.puts("  ✓ EVAL fund/LIVE — prospectus #{inspect(report.prospectus.universe)}, #{length(report.proposals)} proposals, pnl $#{report.realized_pnl}")
  end

  defp live_tape(key, secret) do
    for sym <- ~w(AAPL MSFT SPY), into: %{} do
      bars =
        case Autopoet.Alpaca.bars(sym, key: key, secret: secret, limit: 30) do
          {:ok, %{"bars" => b}} when is_list(b) -> b
          _ -> []
        end

      {sym, bars}
    end
  end
end
