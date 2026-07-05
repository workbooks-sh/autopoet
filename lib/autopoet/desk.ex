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
  @watchlist ~w(AAPL MSFT SPY NVDA QQQ)
  # the 24/7 lane: crypto trades while equities sleep — the desk is never idle
  @crypto_watchlist ["BTC/USD", "ETH/USD", "SOL/USD"]
  @risk_cap 2_000.0
  @max_trades_day 12
  # the desk must be BUSY (>60% of the op doing real work): a research cycle
  # every 15min around the clock + trade cycles when open ≈ ~100-150 calls/day
  @max_llm_day 150
  @research_every 900
  # the rotating research agenda — deeper research + refining methods/processes
  @agenda ~w(deep_dive backtest refine_playbook postmortem refine_process)a
  # July = EDT. Hard offset (no tzdata dep); revisit before November (issues.log will flag).
  @et_offset -4

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Desk snapshot: phase, counters, last runs, pnl."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(nil) do
    File.mkdir_p!(artifacts())

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
      last_crypto_cycle: 0,
      last_study: 0,
      last_research: 0,
      agenda_idx: 0,
      work_cycles: 0,
      equity_open: nil,
      pnl_days: [],
      cycles: 0
    }
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, Map.take(s, [:day, :llm_calls, :trades, :done, :cycles, :equity_open, :pnl_days, :work_cycles, :agenda_idx]), s}
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
        # trade cycle every 30 minutes; research keeps running between them
        cond do
          System.os_time(:second) - s.last_market_cycle >= 1_800 ->
            trade_cycle(%{s | last_market_cycle: System.os_time(:second)})

          research_due?(s) ->
            research_cycle(touch_research(s))

          true ->
            s
        end

      state when state in [:closed_today, :closed_now] ->
        cond do
          hour >= 7.0 and hour < 9.5 and not done?(s, :premarket) and state == :closed_now ->
            premarket(mark(s, :premarket))

          hour >= 16.0 and hour < 17.5 and not done?(s, :review) and state == :closed_now ->
            review(mark(s, :review))

          # crypto never closes: a trade cycle every 30min while equities sleep
          System.os_time(:second) - s.last_crypto_cycle >= 1_800 ->
            crypto_cycle(%{s | last_crypto_cycle: System.os_time(:second)})

          # the engine: a research/refinement cycle every 15min, around the clock
          research_due?(s) ->
            research_cycle(touch_research(s))

          true ->
            s
        end

      :unknown ->
        s
    end
  end

  defp research_due?(s), do: System.os_time(:second) - s.last_research >= @research_every
  defp touch_research(s), do: %{s | last_research: System.os_time(:second)}

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


  defp crypto_cycle(s) do
    if s.trades >= @max_trades_day do
      s
    else
      log("crypto cycle (#{s.trades}/#{@max_trades_day} trades today)")

      with {:ok, s, reply} <- think(s, :crypto, crypto_prompt(s)) do
        execute_orders(s, reply)
      end
    end
  end

  defp crypto_prompt(s) do
    stats = Enum.map_join(@crypto_watchlist, "\n", fn sym -> "#{sym}:\n#{stats_text(sym)}" end)

    """
    You are the autopoet trading desk — CRYPTO CYCLE (24/7 lane) #{s.day}. Paper account.
    Your playbook:
    #{read_body("fund/playbook.work")}
    Positions:
    #{positions_text()}
    Computed stats:
    #{stats}

    HARD LIMITS: per-order notional cap $#{@risk_cap}; pairs only #{inspect(@crypto_watchlist)};
    fractional qty fine (e.g. 0.02); #{@max_trades_day - s.trades} trades left today.

    EITHER hold (say why, no blocks) OR emit order blocks:
    === action: alpaca_place_order ===
    symbol: BTC/USD
    qty: 0.02
    side: buy|sell
    """
  end

  # ── the research engine: rotating agenda, one deep unit of work per cycle ───

  defp research_cycle(s) do
    task = Enum.at(@agenda, rem(s.agenda_idx, length(@agenda)))
    s = %{s | agenda_idx: s.agenda_idx + 1}
    log("research cycle: #{task} (#{s.work_cycles + 1} work cycles)")

    {prompt, artifact} = research_task(task, s)

    with {:ok, s, reply} <- think(s, task, prompt) do
      append_body(artifact, "\n## #{task} #{s.day} ##{s.work_cycles + 1}\n\n" <> strip_actions(reply))
      %{s | work_cycles: s.work_cycles + 1}
    end
  end

  defp research_task(:deep_dive, s) do
    pool = @watchlist ++ @crypto_watchlist
    sym = Enum.at(pool, rem(s.agenda_idx, length(pool)))

    {"""
     You are the autopoet trading desk — DEEP DIVE on #{sym}. Computed stats:
     #{stats_text(sym)}
     Your current playbook:
     #{read_body("fund/playbook.work")}

     Produce a structural read: trend state, key levels, volatility regime, how
     THIS name fits the playbook's setups, and one falsifiable observation to
     verify next session. Plain prose, specific numbers.
     """, "fund/research.work"}
  end

  defp research_task(:backtest, s) do
    pool = @watchlist ++ @crypto_watchlist
    sym = Enum.at(pool, rem(s.agenda_idx + 2, length(pool)))

    {"""
     You are the autopoet trading desk — BACKTEST REVIEW on #{sym}. Computed
     performance of the mechanical rules over the last 60 bars:
     #{backtest_text(sym)}
     Your playbook:
     #{read_body("fund/playbook.work")}

     Judge each rule honestly against these numbers: keep, modify (how,
     exactly), or drop. End with the single highest-value refinement.
     """, "fund/research.work"}
  end

  defp research_task(:refine_playbook, _s) do
    {"""
     You are the autopoet trading desk — PLAYBOOK REFINEMENT. Current playbook:
     #{read_body("fund/playbook.work")}
     Recent research notes:
     #{read_body("fund/research.work")}
     Recent journal:
     #{read_body("fund/journal.work")}

     Rewrite the playbook COMPLETE: setups you trade (entry/exit/stop, sized
     under $#{@risk_cap}/order), setups you skip, and what you changed since the
     last version + why. This replaces the old playbook — be complete.
     """, "fund/playbook.work"}
  end

  defp research_task(:postmortem, s) do
    {"""
     You are the autopoet trading desk — POSTMORTEM #{s.day}. Trades today: #{s.trades}. Day P&L history: #{inspect(s.pnl_days)}.
     Positions:
     #{positions_text()}
     Journal:
     #{read_body("fund/journal.work")}

     Honest postmortem: decisions vs outcomes, process errors (not price luck),
     one concrete rule change. Plain prose.
     """, "fund/journal.work"}
  end

  defp research_task(:refine_process, s) do
    {"""
     You are the autopoet trading desk — PROCESS REVIEW. Your operating process:
     #{read_body("fund/process.work")}
     Your day so far: #{s.llm_calls} research/trade calls, #{s.trades} trades, work cycles #{s.work_cycles}.

     Refine the desk's own PROCESS (not the trades): research rotation, what to
     check before entries, journal discipline, information you keep missing.
     Rewrite the process doc COMPLETE — this replaces it.
     """, "fund/process.work"}
  end

  # ── native-computed stats (the brain reasons over numbers we compute) ───────

  defp stats_text(sym) do
    case Autopoet.Alpaca.bars(sym, limit: 60) do
      {:ok, %{"bars" => bars}} when is_list(bars) and length(bars) >= 20 ->
        closes = Enum.map(bars, & &1["c"])
        vols = Enum.map(bars, & &1["v"])
        last = List.last(closes)
        ma5 = mean(Enum.take(closes, -5))
        ma20 = mean(Enum.take(closes, -20))
        mom10 = Float.round((last / Enum.at(closes, -min(11, length(closes))) - 1) * 100, 2)
        rets = returns(closes)
        vol = Float.round(stdev(rets) * :math.sqrt(252) * 100, 1)
        hi = Enum.max(Enum.take(closes, -20))
        lo = Enum.min(Enum.take(closes, -20))

        "- last #{last} | MA5 #{Float.round(ma5, 2)} | MA20 #{Float.round(ma20, 2)} (#{if ma5 > ma20, do: "5>20 up", else: "5<20 down"})\n" <>
          "- 10d momentum #{mom10}% | ann.vol #{vol}% | 20d range #{lo}-#{hi}\n" <>
          "- avg vol #{trunc(mean(Enum.take(vols, -20)))} | last vol #{List.last(vols)}"

      _ ->
        "- no data"
    end
  end

  defp backtest_text(sym) do
    case Autopoet.Alpaca.bars(sym, limit: 60) do
      {:ok, %{"bars" => bars}} when is_list(bars) and length(bars) >= 25 ->
        closes = Enum.map(bars, & &1["c"])

        # rule A: hold while MA5 > MA20 (recomputed each bar)
        a = rule_returns(closes, fn window -> mean(Enum.take(window, -5)) > mean(Enum.take(window, -20)) end)
        # rule B: hold after an up day
        b = rule_returns(closes, fn window -> length(window) >= 2 and List.last(window) > Enum.at(window, -2) end)
        bh = Float.round((List.last(closes) / hd(closes) - 1) * 100, 2)

        "- buy&hold 60 bars: #{bh}%\n- rule MA5>MA20 in-market return: #{a}%\n- rule prev-day-up in-market return: #{b}%"

      _ ->
        "- no data"
    end
  end

  defp rule_returns(closes, in_market?) do
    {total, _} =
      closes
      |> Enum.with_index()
      |> Enum.reduce({0.0, nil}, fn {c, i}, {acc, prev} ->
        window = Enum.take(closes, i + 1)
        held = i >= 20 and in_market?.(Enum.take(closes, i))
        ret = if held and is_number(prev) and prev > 0, do: c / prev - 1, else: 0.0
        {acc + ret, c}
      end)

    Float.round(total * 100, 2)
  end

  defp returns([_ | _] = closes) do
    closes |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b / a - 1 end)
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp stdev([]), do: 0.0

  defp stdev(xs) do
    m = mean(xs)
    :math.sqrt(Enum.sum(Enum.map(xs, fn x -> (x - m) * (x - m) end)) / max(length(xs), 1))
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

        sym not in @watchlist ++ @crypto_watchlist ->
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
      Path.join(artifacts(), "state.txt"),
      "ts: #{System.os_time(:second)}\nday: #{s.day}\ncycles: #{s.cycles}\nllm_calls: #{s.llm_calls}\ntrades: #{s.trades}\nwork_cycles: #{s.work_cycles}\nagenda_idx: #{s.agenda_idx}\ndone: #{inspect(Map.keys(s.done) |> Enum.filter(&Map.get(s.done, &1)))}\npnl_days: #{inspect(s.pnl_days)}\n"
    )

    File.write!(Path.join(artifacts(), "uptime.log"), "#{System.os_time(:second)}\n", [:append])
    s
  end

  defp issue(msg) do
    line = "#{DateTime.to_iso8601(DateTime.utc_now())} | #{msg}\n"
    File.write!(Path.join(artifacts(), "issues.log"), line, [:append])
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

  # artifacts dir — env-overridable so a TEST desk never clobbers the live op's
  # heartbeat/issues files (the ops monitor's feed)
  defp artifacts, do: System.get_env("AUTOPOET_DESK_DIR") || "eval/desk"

  defp num(n) when is_number(n), do: n
  defp num(s) when is_binary(s), do: (case Float.parse(s), do: ({f, _} -> f; :error -> 0))
  defp num(_), do: 0
end
