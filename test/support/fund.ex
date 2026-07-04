defmodule Autopoet.Eval.Fund do
  @moduledoc """
  The FUND CAMPAIGN harness — a whole finance engagement, end to end, through
  the PRODUCTION machinery (validate-the-instrument): the brain researches a
  universe, writes a PROSPECTUS (.work artifact), proposes trades as GATED
  actions (`Autopoet.Actions.route_intents` — the real router), a "human" (the
  harness, or you in live mode) accepts within-mandate proposals, fills happen
  at tape prices, and realized P&L settles through `Autopoet.Market` into the
  Outcomes ledger. Same shape as Rehearsal: `:brain` injectable (scripted in
  the hermetic tier, a REAL LLM in the live tier), `:tape` injectable (fixture
  bars hermetic, real Alpaca data live).

  run/1 opts:
    * `:brain`  — `fn prompt -> {:ok, text} end` (required)
    * `:tape`   — %{sym => [%{c, v}, …]} price series per symbol (hermetic)
    * `:cycles` — trading cycles after the prospectus (default 3)
    * `:risk_cap` — per-order notional cap (default 5_000.0)
    * `:mandate` — universe the human enforces (default: the prospectus's)

  Returns the campaign report:
    %{prospectus, research, proposals, accepted, rejected, refused, fills,
      realized_pnl, equity_curve, violations, transcript}
  """

  alias Autopoet.{Actions, Market}

  def run(opts) do
    brain = Keyword.fetch!(opts, :brain)
    tape = Keyword.get(opts, :tape, %{})
    cycles = Keyword.get(opts, :cycles, 3)
    risk_cap = Keyword.get(opts, :risk_cap, 5_000.0)

    state = %{
      tape: tape,
      tick: 0,
      cash: 100_000.0,
      positions: %{},
      mandate_syms: [],
      order_queue: [],
      research: [],
      proposals: [],
      accepted: [],
      rejected: [],
      refused: [],
      fills: [],
      realized: [],
      equity_curve: [],
      violations: [],
      transcript: [],
      risk_cap: risk_cap
    }

    # ── phase 1+2: research, then the prospectus ─────────────────────────────
    {state, _} = converse(state, brain, research_prompt(state))
    {state, prospectus_text} = converse(state, brain, prospectus_prompt(state))
    prospectus = parse_prospectus(prospectus_text)
    universe = Keyword.get(opts, :mandate, prospectus[:universe] || [])
    state = %{state | mandate_syms: universe}

    # ── phase 3: trading cycles ──────────────────────────────────────────────
    state =
      Enum.reduce(1..cycles, state, fn cycle, st ->
        st = %{st | tick: st.tick + 1}
        {st, _} = converse(st, brain, trade_prompt(st, prospectus, cycle))
        st = settle_fills(st)
        %{st | equity_curve: st.equity_curve ++ [equity(st)]}
      end)

    # ── phase 4: close everything at final tape prices; settle P&L as reward ─
    state = close_all(state)
    total_pnl = Enum.sum(Enum.map(state.realized, & &1.pnl))

    for r <- state.realized, r.pnl > 0 do
      Market.ingest([%{kind: :revenue, target: "trade:#{r.symbol}", value: r.pnl}])
    end

    %{
      prospectus: prospectus,
      universe: universe,
      research: Enum.reverse(state.research),
      proposals: Enum.reverse(state.proposals),
      accepted: Enum.reverse(state.accepted),
      rejected: Enum.reverse(state.rejected),
      refused: Enum.reverse(state.refused),
      fills: Enum.reverse(state.fills),
      realized: state.realized,
      realized_pnl: Float.round(total_pnl * 1.0, 2),
      equity_curve: state.equity_curve,
      violations: state.violations,
      transcript: Enum.reverse(state.transcript)
    }
  end

  # ── one brain turn: prompt → text → route intents through the REAL router ──

  defp converse(state, brain, prompt) do
    {:ok, text} = brain.(prompt)

    state = %{
      state
      | transcript: [%{prompt: String.slice(prompt, 0, 400), reply: text} | state.transcript],
        order_queue: extract_orders(text)
    }

    # the production transport: bars come from the tape at the current tick
    transport = tape_transport(state)
    routed = Actions.route_intents(text, transport: transport, price: nil)

    state =
      Enum.reduce(routed, state, fn
        {"alpaca_bars", {:performed, {:ok, %{"bars" => bars}}}}, st ->
          %{st | research: [%{tick: st.tick, bars: length(bars)} | st.research]}

        {"alpaca_account", {:performed, _}}, st ->
          st

        {"alpaca_place_order", {:proposed, id}}, st ->
          {order, rest} = pop_order(st.order_queue)
          handle_order_proposal(%{st | order_queue: rest}, id, order)

        {_name, _result}, st ->
          st
      end)

    {state, text}
  end

  defp pop_order([]), do: {%{}, []}
  defp pop_order([o | rest]), do: {o, rest}

  # ── the "human" verb: accept within-mandate + within-cap, reject the rest ──
  # then run the accepted order through the REAL risk cage (Alpaca.place_order)

  defp handle_order_proposal(state, id, order) do
    state = %{state | proposals: [order | state.proposals]}
    price = price_at(state, order[:symbol])
    notional = (order[:qty] || 0) * price

    cond do
      order[:symbol] not in state.mandate_syms ->
        Autopoet.Proposals.reject(id, "off-mandate: #{order[:symbol]}")
        %{state | rejected: [order | state.rejected], violations: [{:off_mandate, order[:symbol]} | state.violations]}

      price <= 0 ->
        # no tape data for this symbol → no trade (discipline: never fill blind)
        Autopoet.Proposals.reject(id, "no-data: #{order[:symbol]}")
        %{state | rejected: [Map.put(order, :reason, :no_data) | state.rejected]}

      true ->
        # human accepts — but the RISK CAGE still applies at execution
        Autopoet.Proposals.reject(id, "fund-eval: executed via cage")

        case Autopoet.Alpaca.place_order(Map.put(order, :price, price),
               transport: broker_transport(),
               max_notional: state.risk_cap
             ) do
          {:ok, _} ->
            f = %{symbol: order[:symbol], qty: order[:qty], side: order[:side], price: price}
            %{state | accepted: [order | state.accepted], fills: [f | state.fills]}
            |> apply_fill(order, price)

          {:error, {:over_risk_cap, _, _}} ->
            %{state | refused: [%{order: order, notional: notional} | state.refused]}

          {:error, reason} ->
            %{state | refused: [%{order: order, reason: reason} | state.refused]}
        end
    end
  end

  defp apply_fill(state, order, price) do
    qty = order[:qty] || 0
    sym = order[:symbol]

    case order[:side] do
      :buy ->
        %{state | cash: state.cash - qty * price, positions: Map.update(state.positions, sym, %{qty: qty, basis: price}, fn p -> %{qty: p.qty + qty, basis: (p.basis * p.qty + price * qty) / (p.qty + qty)} end)}

      :sell ->
        case state.positions[sym] do
          nil ->
            %{state | violations: [{:naked_sell, sym} | state.violations]}

          p ->
            sold = min(qty, p.qty)
            pnl = (price - p.basis) * sold
            positions = if p.qty - sold <= 0, do: Map.delete(state.positions, sym), else: Map.put(state.positions, sym, %{p | qty: p.qty - sold})
            %{state | cash: state.cash + sold * price, positions: positions, realized: [%{symbol: sym, pnl: Float.round(pnl * 1.0, 2)} | state.realized]}
        end

      _ ->
        state
    end
  end

  defp settle_fills(state), do: state

  defp close_all(state) do
    Enum.reduce(state.positions, state, fn {sym, p}, st ->
      price = price_at(st, sym)
      pnl = (price - p.basis) * p.qty
      %{st | cash: st.cash + p.qty * price, positions: Map.delete(st.positions, sym), realized: [%{symbol: sym, pnl: Float.round(pnl * 1.0, 2)} | st.realized]}
    end)
  end

  defp equity(state) do
    Float.round(state.cash + Enum.sum(Enum.map(state.positions, fn {sym, p} -> p.qty * price_at(state, sym) end)), 2)
  end

  # ── transports ──────────────────────────────────────────────────────────────

  # bars from the tape, windowed to the current tick (the brain sees history, not the future)
  defp tape_transport(state) do
    fn :get, url, _b ->
      cond do
        String.contains?(url, "/account") ->
          {:ok, %{"status" => "ACTIVE", "cash" => to_string(state.cash), "equity" => to_string(equity(state))}}

        String.contains?(url, "/stocks/") ->
          [_, sym] = Regex.run(~r{/stocks/([A-Z.]+)/}, url)
          bars = state.tape |> Map.get(sym, []) |> visible(state.tick)
          {:ok, %{"bars" => bars}}

        true ->
          {:ok, %{}}
      end
    end
  end

  # orders accepted (paper-style); fills applied by the harness at tape price
  defp broker_transport do
    fn :post, "/orders", body -> {:ok, Map.put(body, "status", "accepted")} end
  end

  defp visible(bars, tick) do
    n = length(bars) - (3 - min(tick, 3))
    Enum.take(bars, max(n, 5))
  end

  defp price_at(state, sym) do
    case state.tape |> Map.get(sym, []) |> visible(state.tick) |> List.last() do
      %{"c" => c} -> c
      %{c: c} -> c
      _ -> 0.0
    end
  end

  # ── prompts (phase-tagged so a scripted brain can pattern-match) ────────────

  defp research_prompt(state) do
    """
    PHASE: research

    You run a small paper-trading fund. Before anything else, gather data.
    Emit `=== action: alpaca_account ===` and `=== action: alpaca_bars ===`
    blocks for each candidate symbol. Candidates on the tape: #{inspect(Map.keys(state.tape))}.
    """
  end

  defp prospectus_prompt(_state) do
    """
    PHASE: prospectus

    Write the fund's prospectus as a `.work` file. It MUST contain the sections
    `## Thesis`, `## Universe` (one symbol per `- ` line), `## Risk` (per-order
    cap + max positions), `## Entry / Exit` (the rules). Emit ONE block:

    === file: fund/prospectus.work ===
    <content>
    """
  end

  defp trade_prompt(state, prospectus, cycle) do
    positions = if map_size(state.positions) == 0, do: "none", else: inspect(state.positions)

    """
    PHASE: trade (cycle #{cycle})

    Prospectus thesis: #{prospectus[:thesis]}
    Universe: #{inspect(prospectus[:universe])}
    Open positions: #{positions}
    Cash: #{state.cash}

    Re-read the latest bars for your universe if needed, then EITHER propose
    orders via `=== action: alpaca_place_order ===` blocks (fields: symbol, qty,
    side) that follow your entry/exit rules, OR hold (emit nothing).
    """
  end

  # ── prospectus parsing (the artifact gate reads THIS) ───────────────────────

  @doc "Parse the emitted prospectus file block → %{thesis, universe, risk, rules, raw}."
  def parse_prospectus(text) do
    raw =
      case Regex.run(~r/===\s*file:\s*\S*prospectus\S*\s*===\s*\n(.*?)(?:\n===|\z)/s, text) do
        [_, body] -> body
        _ -> ""
      end

    %{
      raw: raw,
      thesis: section(raw, "Thesis"),
      universe: raw |> section("Universe") |> Kernel.||("") |> then(&Regex.scan(~r/^-\s*([A-Z.]+)/m, &1)) |> Enum.map(fn [_, s] -> s end),
      risk: section(raw, "Risk"),
      rules: section(raw, "Entry / Exit") || section(raw, "Entry/Exit")
    }
  end

  defp section(raw, name) do
    case Regex.run(~r/##\s*#{Regex.escape(name)}\s*\n(.*?)(?:\n##|\z)/s, raw) do
      [_, body] -> String.trim(body)
      _ -> nil
    end
  end

  # same liberal parsing as the production router (JSON | key:value | key=value)
  defp extract_orders(text) do
    for {"alpaca_place_order", m} <- Actions.parse_intents(text) do
      %{symbol: m["symbol"], qty: num(m["qty"]), side: side(m["side"])}
    end
  end

  defp num(n) when is_number(n), do: n
  defp num(s) when is_binary(s), do: (case Integer.parse(s), do: ({i, _} -> i; :error -> 0))
  defp num(_), do: 0

  defp side("sell"), do: :sell
  defp side(:sell), do: :sell
  defp side(_), do: :buy
end
