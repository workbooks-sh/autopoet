defmodule Autopoet.Desk do
  @moduledoc """
  The always-on TRADING DESK — the autopoet's day/night cycle around the
  market (the 48-hour live op, wb-siutv). A GenServer that ticks every minute,
  computes the phase from the Alpaca clock + Eastern time, and runs each
  phase's work on its own cadence:

    * premarket (07:00–09:30 ET, once)  — morning research: account, bars,
      write the day plan to the body (fund/plan.work).
    * market (clock says open, /30min)  — trade cycle: brain reads plan +
      positions + bars, proposes orders; within-mandate + within-cap orders
      EXECUTE on the PAPER account (the cage IS the gate here: paper-only,
      hard caps); everything else refused + logged.
    * afterhours (16:00–17:00 ET, once) — review: equity vs yesterday, settle
      the day's P&L into the reward ledger, journal (fund/journal.work).
    * night (21:00–23:00 ET, once)      — deep research: next-day watchlist.
    * closed day (weekend/holiday)      — study cycle every 4h (research only).

  SAFETY RAILS (all hard, none prompt-level): paper endpoint only (never
  opts[:live]); per-order notional cap; max trades/day; max LLM calls/day;
  every exception caught → one line in eval/desk/issues.log (the monitor's
  feed) → the desk keeps ticking. State durable via Autopoet.Shadow; a
  heartbeat line lands in eval/desk/state.txt every tick so an external
  monitor can see liveness. Enabled only when AUTOPOET_DESK=1.
  """
  use GenServer
  require Logger

  @tick 60_000
  @artifacts "eval/desk"
  @watchlist ~w(AAPL MSFT SPY NVDA QQQ)
  @risk_cap 2_000.0
  @max_trades_day 8
  @max_llm_day 30
  # July = EDT. Hard offset (no tzdata dep); revisit before November (issues.log will flag).
  @et_offset -4

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Desk snapshot: phase, counters, last runs, pnl."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(nil) do
    File.mkdir_p!(@artifacts)

    state =
      case Autopoet.Shadow.load("desk") do
        {:ok, s} -> Map.merge(defaults(), s)
        :none -> defaults()
      end

    state = %{state | started_at: System.os_time(:second)}
    Process.send_after(self(), :tick, 5_000)
    log("desk up — watchlist #{inspect(@watchlist)} cap $#{@risk_cap}/order")
    {:ok, state}
  end

  defp defaults do
    %{
      started_at: nil,
      day: nil,
      llm_calls: 0,
      trades: 0,
      done: %{},
      last_market_cycle: 0,
      last_study: 0,
      equity_open: nil,
      pnl_days: [],
      cycles: 0
    }
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, Map.take(s, [:day, :llm_calls, :trades, :done, :cycles, :equity_open, :pnl_days]), s}
  end

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick)

    s =
      try do
        s |> roll_day() |> heartbeat() |> phase_step()
      rescue
        e ->
          issue("tick crashed: #{Exception.message(e)} #{inspect(Enum.take(__STACKTRACE__, 3))}")
          s
      catch
        kind, reason ->
          issue("tick threw: #{inspect(kind)} #{inspect(reason)}")
          s
      end

    Autopoet.Shadow.save("desk", Map.delete(s, :started_at))
    {:noreply, %{s | cycles: s.cycles + 1}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── the day/night cycle ─────────────────────────────────────────────────────

  defp phase_step(s) do
    now = et_now()
    hour = now.hour + now.minute / 60

    case market_state() do
      :open ->
        # trade cycle every 30 minutes while the market is open
        if System.os_time(:second) - s.last_market_cycle >= 1_800,
          do: trade_cycle(%{s | last_market_cycle: System.os_time(:second)}),
          else: s

      :closed_today ->
        # weekend/holiday: study every 4h
        if System.os_time(:second) - s.last_study >= 14_400,
          do: study_cycle(%{s | last_study: System.os_time(:second)}),
          else: s

      :closed_now ->
        cond do
          hour >= 7.0 and hour < 9.5 and not done?(s, :premarket) -> premarket(mark(s, :premarket))
          hour >= 16.0 and hour < 17.5 and not done?(s, :review) -> review(mark(s, :review))
          hour >= 21.0 and hour < 23.0 and not done?(s, :night) -> night_research(mark(s, :night))
          true -> s
        end

      :unknown ->
        s
    end
  end

  # ── phases ──────────────────────────────────────────────────────────────────

  defp premarket(s) do
    log("premarket research")

    with {:ok, s, reply} <- think(s, :premarket, premarket_prompt(s)) do
      write_body("fund/plan.work", "# Day plan #{s.day}\n\n" <> strip_actions(reply))
      s
    end
  end

  defp trade_cycle(s) do
    if s.trades >= @max_trades_day do
      s
    else
      log("trade cycle (#{s.trades}/#{@max_trades_day} trades today)")

      with {:ok, s, reply} <- think(s, :trade, trade_prompt(s)) do
        execute_orders(s, reply)
      end
    end
  end

  defp review(s) do
    log("afterhours review")
    equity = current_equity()

    s =
      case {s.equity_open, equity} do
        {open, eq} when is_number(open) and is_number(eq) ->
          pnl = Float.round(eq - open, 2)
          if pnl > 0, do: Autopoet.Market.ingest([%{kind: :revenue, target: "desk:#{s.day}", value: pnl}])
          %{s | pnl_days: Enum.take([{s.day, pnl} | s.pnl_days], 30)}

        _ ->
          s
      end

    with {:ok, s, reply} <- think(s, :review, review_prompt(s, equity)) do
      append_body("fund/journal.work", "\n## #{s.day} (equity #{inspect(equity)})\n\n" <> strip_actions(reply))
      s
    end
  end

  defp night_research(s) do
    log("night research")

    with {:ok, s, reply} <- think(s, :night, night_prompt(s)) do
      append_body("fund/plan.work", "\n## Overnight notes #{s.day}\n\n" <> strip_actions(reply))
      s
    end
  end

  defp study_cycle(s) do
    log("closed-day study")

    with {:ok, s, reply} <- think(s, :study, study_prompt(s)) do
      append_body("fund/journal.work", "\n## Study #{s.day}\n\n" <> strip_actions(reply))
      s
    end
  end

  # ── the brain call (budgeted) ───────────────────────────────────────────────

  defp think(s, phase, prompt) do
    if s.llm_calls >= @max_llm_day do
      issue("llm budget exhausted (#{@max_llm_day}/day) in #{phase}")
      s
    else
      case Autopoet.Providers.openrouter([%{role: "user", content: prompt}], max_tokens: 1200, temperature: 0.3) do
        {:ok, %{content: reply}} when is_binary(reply) ->
          {:ok, %{s | llm_calls: s.llm_calls + 1}, reply}

        other ->
          issue("llm failed in #{phase}: #{inspect(other) |> String.slice(0, 200)}")
          %{s | llm_calls: s.llm_calls + 1}
      end
    end
  end

  # a phase helper returning plain state must flow through the with-clauses
  defp strip_actions(text), do: Regex.replace(~r/===\s*action:.*?(?=\n\n|\z)/s, text, "")

  # ── order execution: the cage is the gate (paper + caps) ────────────────────

  defp execute_orders(s, reply) do
    orders = for {"alpaca_place_order", m} <- Autopoet.Actions.parse_intents(reply), do: m

    Enum.reduce(orders, s, fn m, st ->
      sym = String.upcase(to_string(m["symbol"] || ""))
      qty = num(m["qty"])
      side = if to_string(m["side"]) == "sell", do: :sell, else: :buy
      price = last_price(sym)

      cond do
        st.trades >= @max_trades_day ->
          st

        sym not in @watchlist ->
          issue("off-watchlist order refused: #{sym}")
          st

        price <= 0 or qty <= 0 ->
          issue("blind/invalid order refused: #{sym} qty=#{qty} price=#{price}")
          st

        true ->
          case Autopoet.Alpaca.place_order(%{symbol: sym, qty: qty, side: side, price: price}, max_notional: @risk_cap) do
            {:ok, _} ->
              log("FILL #{side} #{qty} #{sym} @ ~#{price}")
              %{st | trades: st.trades + 1}

            {:error, reason} ->
              issue("order refused #{sym} x#{qty}: #{inspect(reason)}")
              st
          end
      end
    end)
  end

  # ── market data helpers ─────────────────────────────────────────────────────

  defp market_state do
    case Autopoet.Alpaca.clock() do
      {:ok, %{"is_open" => true}} ->
        :open

      {:ok, %{"is_open" => false, "next_open" => next}} ->
        # closed all day if next open is not today (ET)
        today = Date.to_iso8601(et_now() |> DateTime.to_date())
        if is_binary(next) and String.starts_with?(next, today), do: :closed_now, else: closed_kind(next)

      _ ->
        :unknown
    end
  end

  defp closed_kind(next) when is_binary(next) do
    # next open more than ~20h away → treat as a closed day (weekend/holiday)
    case DateTime.from_iso8601(next) do
      {:ok, dt, _} ->
        if DateTime.diff(dt, DateTime.utc_now()) > 72_000, do: :closed_today, else: :closed_now

      _ ->
        :closed_now
    end
  end

  defp closed_kind(_), do: :closed_now

  defp last_price(sym) do
    case Autopoet.Alpaca.bars(sym, limit: 1) do
      {:ok, %{"bars" => [%{"c" => c} | _]}} -> c
      {:ok, %{"bars" => bars}} when is_list(bars) and bars != [] -> List.last(bars)["c"]
      _ -> 0.0
    end
  end

  defp current_equity do
    case Autopoet.Alpaca.account() do
      {:ok, %{"equity" => e}} -> num(e)
      _ -> nil
    end
  end

  defp positions_text do
    case Autopoet.Alpaca.positions() do
      {:ok, ps} when is_list(ps) and ps != [] ->
        Enum.map_join(ps, "\n", fn p -> "- #{p["symbol"]}: #{p["qty"]} @ #{p["avg_entry_price"]} (P&L #{p["unrealized_pl"]})" end)

      _ ->
        "none"
    end
  end

  defp bars_text do
    Enum.map_join(@watchlist, "\n", fn sym ->
      case Autopoet.Alpaca.bars(sym, limit: 10) do
        {:ok, %{"bars" => bars}} when is_list(bars) and bars != [] ->
          closes = Enum.map(bars, & &1["c"])
          "- #{sym}: last #{List.last(closes)}, 10d #{inspect(closes)}"

        _ ->
          "- #{sym}: no data"
      end
    end)
  end

  # ── prompts ─────────────────────────────────────────────────────────────────

  defp premarket_prompt(s) do
    """
    You are the autopoet trading desk, PREMARKET #{s.day}. Paper account. Watchlist: #{inspect(@watchlist)}.
    Recent bars:
    #{bars_text()}
    Positions:
    #{positions_text()}

    Write today's plan: regime read, 1-3 setups from the watchlist with entry/exit
    levels, and what would invalidate them. Per-order hard cap $#{@risk_cap}. Plain prose.
    """
  end

  defp trade_prompt(s) do
    """
    You are the autopoet trading desk, MARKET OPEN #{s.day}. Paper account.
    Today's plan (follow it — deviation must be justified):
    #{read_body("fund/plan.work")}
    Positions:
    #{positions_text()}
    Latest bars:
    #{bars_text()}

    HARD LIMITS: per-order notional cap $#{@risk_cap}; watchlist-only #{inspect(@watchlist)};
    #{@max_trades_day - s.trades} trades left today.

    EITHER hold (say why, no blocks) OR emit order blocks:
    === action: alpaca_place_order ===
    symbol: SYM
    qty: N
    side: buy|sell
    """
  end

  defp review_prompt(s, equity) do
    """
    You are the autopoet trading desk, AFTERHOURS REVIEW #{s.day}. Equity: #{inspect(equity)} (opened #{inspect(s.equity_open)}).
    Positions:
    #{positions_text()}

    Journal today honestly: what worked, what didn't, what to change tomorrow. Plain prose.
    """
  end

  defp night_prompt(s) do
    """
    You are the autopoet trading desk, NIGHT RESEARCH #{s.day}.
    Bars:
    #{bars_text()}

    Deep read for tomorrow: which watchlist names have the cleanest structure,
    key levels, what regime shift would change the plan. Plain prose.
    """
  end

  defp study_prompt(s) do
    """
    You are the autopoet trading desk, MARKET CLOSED (weekend/holiday) #{s.day}.
    Bars:
    #{bars_text()}

    Study session: review the week's structure on the watchlist, refine the
    playbook (setups you'll trade, ones you'll skip). Plain prose.
    """
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp roll_day(s) do
    today = et_now() |> DateTime.to_date() |> Date.to_iso8601()

    if s.day == today do
      s
    else
      log("new day #{today} — counters reset")
      %{s | day: today, llm_calls: 0, trades: 0, done: %{}, equity_open: current_equity()}
    end
  end

  defp done?(s, phase), do: Map.get(s.done, phase, false)
  defp mark(s, phase), do: %{s | done: Map.put(s.done, phase, true)}

  defp et_now, do: DateTime.add(DateTime.utc_now(), @et_offset * 3600, :second)

  defp heartbeat(s) do
    File.write!(
      Path.join(@artifacts, "state.txt"),
      "ts: #{System.os_time(:second)}\nday: #{s.day}\ncycles: #{s.cycles}\nllm_calls: #{s.llm_calls}\ntrades: #{s.trades}\ndone: #{inspect(Map.keys(s.done) |> Enum.filter(&Map.get(s.done, &1)))}\npnl_days: #{inspect(s.pnl_days)}\n"
    )

    File.write!(Path.join(@artifacts, "uptime.log"), "#{System.os_time(:second)}\n", [:append])
    s
  end

  defp issue(msg) do
    line = "#{DateTime.to_iso8601(DateTime.utc_now())} | #{msg}\n"
    File.write!(Path.join(@artifacts, "issues.log"), line, [:append])
    log("ISSUE: #{msg}")
  end

  defp log(msg) do
    Autopoet.Log.puts("desk: #{msg}")
  rescue
    _ -> Logger.info("desk: #{msg}")
  end

  defp write_body(path, content) do
    Autopoet.Body.apply(%{path => content}, %{})
  rescue
    e -> issue("body write #{path} failed: #{Exception.message(e)}")
  end

  defp append_body(path, content) do
    Autopoet.Body.apply(%{}, %{path => content})
  rescue
    e -> issue("body append #{path} failed: #{Exception.message(e)}")
  end

  defp read_body(path) do
    case File.read(Path.join(Autopoet.Body.root(), path)) do
      {:ok, c} -> String.slice(c, 0, 3000)
      _ -> "(no plan yet)"
    end
  rescue
    _ -> "(no plan yet)"
  end

  defp num(n) when is_number(n), do: n
  defp num(s) when is_binary(s), do: (case Float.parse(s), do: ({f, _} -> f; :error -> 0))
  defp num(_), do: 0
end
