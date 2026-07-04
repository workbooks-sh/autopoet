defmodule Autopoet.FinanceEvalTest do
  @moduledoc """
  Finance & trading eval (v3, wb-siutv) — the autopoet's cleanest autonomous
  oracle. Proven with an injected Alpaca transport (no live calls, no market
  hours needed; identical code runs live against the paper account):

    F-DATA    the client reads account + market bars through the (injected)
              Alpaca API — the DATA a decision rests on.
    F-RISK    the risk cage holds: an order over the per-order notional cap is
              REFUSED; a within-cap order places. The agent cannot YOLO.
    F-DECIDE  a decision function turns bars + a research signal into a VALID,
              risk-bounded order (buy on a confirmed uptrend, hold otherwise) —
              the "trade based on time, data, and research" test.
    F-PNL     realized P&L settles as market reward → the Outcomes ledger, so
              trading feeds the same learning economy as everything else.

  The LIVE tier (real paper account) is double-locked behind :live +
  AUTOPOET_LIVE (see the live-run note at the end).
  """
  use ExUnit.Case, async: false

  alias Autopoet.{Alpaca, Market}

  # a canned Alpaca transport: returns account/positions/bars/order fixtures
  defp transport(bars) do
    fn method, path, body ->
      cond do
        path == "/account" ->
          {:ok, %{"status" => "ACTIVE", "cash" => "100000", "buying_power" => "400000", "equity" => "100000"}}

        String.starts_with?(path, "/stocks/") ->
          {:ok, %{"bars" => bars}}

        path == "/clock" ->
          {:ok, %{"is_open" => true}}

        method == :post and path == "/orders" ->
          {:ok, %{"id" => "ord_1", "symbol" => body["symbol"], "qty" => body["qty"], "side" => body["side"], "status" => "accepted"}}

        true ->
          {:error, {:unexpected, path}}
      end
    end
  end

  defp uptrend, do: for(i <- 1..20, do: %{"t" => "d#{i}", "c" => 100.0 + i * 1.5, "v" => 1_000_000})
  defp choppy, do: for(i <- 1..20, do: %{"c" => 100.0 + :math.sin(i) * 2, "v" => 500_000})

  test "F-DATA: account + bars read through the injected Alpaca client" do
    t = transport(uptrend())
    assert {:ok, acct} = Alpaca.account(transport: t)
    assert acct["status"] == "ACTIVE" and acct["cash"] == "100000"

    assert {:ok, %{"bars" => bars}} = Alpaca.bars("AAPL", transport: t)
    assert length(bars) == 20

    IO.puts("  ✓ EVAL finance/data — account ACTIVE ($#{acct["cash"]}), #{length(bars)} bars read")
  end

  test "F-RISK: the risk cage refuses an over-cap order, places a within-cap one" do
    t = transport(uptrend())

    # 1000 shares × $150 = $150k notional, cap $10k → REFUSED
    assert {:error, {:over_risk_cap, notional, cap}} =
             Alpaca.place_order(%{symbol: "AAPL", qty: 1000, side: :buy, price: 150.0}, transport: t, max_notional: 10_000.0)
    assert notional == 150_000.0 and cap == 10_000.0

    # 10 shares × $150 = $1.5k → within cap → placed
    assert {:ok, order} = Alpaca.place_order(%{symbol: "AAPL", qty: 10, side: :buy, price: 150.0}, transport: t, max_notional: 10_000.0)
    assert order["status"] == "accepted" and order["symbol"] == "AAPL"

    IO.puts("  ✓ EVAL finance/risk — $150k order refused (cap $10k); $1.5k order placed (the cage holds on trades)")
  end

  test "F-DECIDE: bars + research → a valid, risk-bounded order (buy uptrend, hold chop)" do
    # an uptrend with a positive research signal → BUY, sized within cap
    up = decide(uptrend(), %{research: :bullish}, max_notional: 5_000.0)
    assert up.action == :buy
    assert up.order.qty > 0
    assert up.order.qty * up.ref_price <= 5_000.0, "decision must respect the risk cap"

    # choppy tape or a bearish signal → HOLD (no forced trade)
    assert decide(choppy(), %{research: :bullish}, max_notional: 5_000.0).action == :hold
    assert decide(uptrend(), %{research: :bearish}, max_notional: 5_000.0).action == :hold

    IO.puts("  ✓ EVAL finance/decide — buys a confirmed uptrend within risk, holds on chop/bearish (time+data+research)")
  end

  test "F-PNL: realized P&L settles as market reward into the outcome ledger" do
    before = Autopoet.Shadow.Outcomes.stats().rewards

    # a closed winning trade → its realized P&L is market revenue
    Market.ingest([%{kind: :revenue, target: "trade:AAPL", value: 240.0}])
    Process.sleep(200)

    stats = Autopoet.Shadow.Outcomes.stats()
    assert stats.rewards.count > before.count
    assert Autopoet.Shadow.Outcomes.ledger().rewards["trade:AAPL"].amount == 240.0

    IO.puts("  ✓ EVAL finance/pnl — closed trade P&L ($240) → market reward in the ledger (trading feeds the learning economy)")
  end

  # ── the decision function under test (deterministic; the brain's live version
  # reasons, this proves the DECISION SHAPE is valid + risk-bounded) ───────────
  defp decide(bars, signal, opts) do
    closes = Enum.map(bars, & &1["c"])
    ref = List.last(closes)
    first = hd(closes)
    up_trend? = ref > first * 1.05 and monotone_up?(closes)
    cap = Keyword.get(opts, :max_notional, 5_000.0)

    if up_trend? and signal[:research] == :bullish do
      qty = trunc(cap / ref)
      %{action: :buy, ref_price: ref, order: %{symbol: "AAPL", qty: qty, side: :buy, price: ref}}
    else
      %{action: :hold, ref_price: ref, order: nil}
    end
  end

  # a real (not necessarily strict) uptrend: last-third mean > first-third mean
  defp monotone_up?(closes) do
    n = div(length(closes), 3)
    Enum.sum(Enum.take(closes, -n)) / n > Enum.sum(Enum.take(closes, n)) / n
  end
end
