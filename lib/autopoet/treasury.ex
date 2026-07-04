defmodule Autopoet.Treasury do
  @moduledoc """
  The REAL-MONEY boundary (v3 foundation 2, wb-siutv) — the wall around
  autonomous spend of actual dollars (hosting, a domain, ad spend), the analog
  of `Nexus.Inference.Admission` for LLM credit.

  FAIL-SAFE BY DEFAULT (the cage): `enforce: true`, `cap_total: 0` — out of the
  box the autopoet CANNOT spend a single real cent. A human funds it by setting
  a cap (a deploy-time act, like the reward whitelist — frozen config the agent
  cannot raise itself). Raising a cap is always a human act.

  The economics are honest and gradient-free: market REVENUE credits the
  balance, autonomous COSTS debit it. When runway (balance) hits zero the
  autopoet must EARN before it spends again — a real constraint, not a
  simulation. Every charge/refusal emits an auditable bus event.

  State is durable (`treasury.etf`) and reboot-safe. `charge/3` never raises —
  a metering fault must refuse (fail-safe), never crash a run.
  """
  use GenServer

  @snapshot "treasury"

  # fail-safe defaults: enforced, zero cap, zero balance — spends nothing until funded
  @defaults %{
    enforce: true,
    balance: 0.0,
    cap_total: 0.0,
    cap_daily: 0.0,
    spent_total: 0.0,
    spent_today: 0.0,
    earned_total: 0.0,
    day: nil
  }

  # ── client ──

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The readable boundary — balance, caps, spend, runway. Pure read; never raises."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Attempt to spend `amount` USD for `purpose` against `target`. Returns
  `{:ok, balance}` or `{:error, reason}` (`:over_total_cap | :over_daily_cap |
  :insufficient_runway | :nonpositive`). Refuses rather than crashes.
  """
  def charge(amount, purpose, target \\ nil), do: GenServer.call(__MODULE__, {:charge, amount, purpose, target})

  @doc "Credit market REVENUE (the loop's only income). Grows balance + runway."
  def earn(amount, source \\ :market), do: GenServer.call(__MODULE__, {:earn, amount, source})

  @doc "Human-only: fund the treasury with a spending cap. This is the deploy-time act the agent cannot perform itself."
  def fund(cap_total, cap_daily), do: GenServer.call(__MODULE__, {:fund, cap_total, cap_daily})

  @doc "Force a synchronous snapshot (shutdown path + tests)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Reset to fail-safe defaults (test/maintenance)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── server ──

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    state =
      case load() do
        {:ok, saved} -> Map.merge(@defaults, saved)
        :none -> @defaults
      end

    {:ok, roll_day(state)}
  end

  @impl true
  def handle_call(:status, _from, s) do
    s = roll_day(s)

    {:reply,
     %{
       enforce: s.enforce,
       balance: r(s.balance),
       runway: r(s.balance),
       cap_total: r(s.cap_total),
       cap_daily: r(s.cap_daily),
       spent_total: r(s.spent_total),
       spent_today: r(s.spent_today),
       earned_total: r(s.earned_total),
       total_headroom: r(s.cap_total - s.spent_total),
       daily_headroom: r(s.cap_daily - s.spent_today)
     }, s}
  end

  def handle_call({:charge, amount, purpose, target}, _from, s) do
    s = roll_day(s)

    cond do
      not is_number(amount) or amount <= 0 ->
        {:reply, {:error, :nonpositive}, s}

      not s.enforce ->
        # enforcement off ⇒ record but never block (parity with Admission)
        s = %{s | spent_total: s.spent_total + amount, spent_today: s.spent_today + amount, balance: s.balance - amount}
        audit(:charged, amount, purpose, target, s)
        {:reply, {:ok, r(s.balance)}, s}

      s.spent_total + amount > s.cap_total ->
        refuse(:over_total_cap, amount, purpose, target, s)

      s.spent_today + amount > s.cap_daily ->
        refuse(:over_daily_cap, amount, purpose, target, s)

      amount > s.balance ->
        refuse(:insufficient_runway, amount, purpose, target, s)

      true ->
        s = %{s | spent_total: s.spent_total + amount, spent_today: s.spent_today + amount, balance: s.balance - amount}
        audit(:charged, amount, purpose, target, s)
        persist(s)
        {:reply, {:ok, r(s.balance)}, s}
    end
  end

  def handle_call({:earn, amount, source}, _from, s) when is_number(amount) and amount > 0 do
    s = %{s | balance: s.balance + amount, earned_total: s.earned_total + amount}
    emit(%{kind: "treasury.earned", amount: amount * 1.0, source: to_string(source), balance: r(s.balance), tags: []})
    persist(s)
    {:reply, {:ok, r(s.balance)}, s}
  end

  def handle_call({:earn, _amount, _source}, _from, s), do: {:reply, {:error, :nonpositive}, s}

  def handle_call({:fund, cap_total, cap_daily}, _from, s) do
    s = %{s | cap_total: cap_total * 1.0, cap_daily: cap_daily * 1.0}
    emit(%{kind: "treasury.funded", cap_total: cap_total * 1.0, cap_daily: cap_daily * 1.0, tags: []})
    persist(s)
    {:reply, :ok, s}
  end

  def handle_call(:snapshot, _from, s), do: {:reply, persist(s), s}

  def handle_call(:reset, _from, _s) do
    s = roll_day(@defaults)
    persist(s)
    {:reply, :ok, s}
  end

  @impl true
  def terminate(_reason, s), do: persist(s)

  # ── internals ──

  defp refuse(reason, amount, purpose, target, s) do
    emit(%{kind: "treasury.refused", reason: to_string(reason), amount: amount * 1.0, purpose: to_string(purpose), target: to_string(target || "?"), tags: []})
    {:reply, {:error, reason}, s}
  end

  defp audit(_kind, amount, purpose, target, s) do
    emit(%{kind: "treasury.charged", amount: amount * 1.0, purpose: to_string(purpose), target: to_string(target || "?"), balance: r(s.balance), tags: []})
  end

  # a new UTC day resets the daily spend counter
  defp roll_day(s) do
    today = Date.utc_today() |> Date.to_iso8601()
    if s.day == today, do: s, else: %{s | day: today, spent_today: 0.0}
  end

  defp emit(ev) do
    Nexus.Events.emit(ev)
  rescue
    _ -> :ok
  end

  defp r(n), do: Float.round(n * 1.0, 4)

  defp persist(s), do: Autopoet.Shadow.save(@snapshot, Map.take(s, Map.keys(@defaults)))
  defp load, do: Autopoet.Shadow.load(@snapshot)
end
