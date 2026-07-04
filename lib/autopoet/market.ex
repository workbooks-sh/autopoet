defmodule Autopoet.Market do
  @moduledoc """
  The MARKET oracle (v3 foundation 1, wb-siutv) — the only source of TRUE reward
  in the autonomous business loop. Where the eval fixtures fed synthetic life,
  this ingests UNFAKEABLE external signals from the autopoet's own deployed
  site — pageviews, signups, revenue — and settles them two ways:

    * as `reward.landed` events → the Outcomes ledger (the learning signal,
      keyed by the business target so credit flows to what produced the win);
    * revenue specifically → `Autopoet.Treasury.earn` (the runway that funds
      the next autonomous spend).

  The market is the JUDGE (a real dollar, a real signup — nothing the system can
  fabricate). No LLM opinion enters here; this is the boundary that keeps the
  loop honest.

  Signals arrive through an INJECTABLE poller (`:source` opt) — evals feed a
  fixed batch, production polls a real analytics backend (Cloudflare Web
  Analytics / Plausible / the site's own event beacons). Each signal is a map:
  `%{kind: :view | :signup | :revenue, target: <locus>, value: number}`.
  """

  # per-signal reward weight (learning signal magnitude — NOT dollars; revenue
  # carries its own dollar value straight to the treasury)
  @weights %{view: 0.01, signup: 1.0, revenue: 0.0}

  @doc """
  Ingest a batch of market signals. Settles reward for every signal and credits
  the treasury for revenue. Returns a tally `%{views, signups, revenue_usd,
  reward_events}`. Pure over its inputs apart from the two settlement effects.
  """
  def ingest(signals) when is_list(signals) do
    Enum.reduce(signals, %{views: 0, signups: 0, revenue_usd: 0.0, reward_events: 0}, fn sig, acc ->
      kind = sig[:kind] || sig["kind"]
      target = to_string(sig[:target] || sig["target"] || "site")
      value = (sig[:value] || sig["value"] || 1) * 1.0

      _ = settle(kind, target, value)

      acc
      |> bump(kind, value)
      |> Map.update!(:reward_events, &(&1 + 1))
    end)
  end

  @doc "Poll the configured market source once and ingest whatever it returns. `:source` is `(-> [signal])` (evals inject; production polls analytics)."
  def poll(opts \\ []) do
    source = Keyword.get(opts, :source, &no_source/0)
    ingest(source.())
  end

  # ── settlement: reward to the ledger, revenue to the treasury ───────────────

  defp settle(:revenue, target, usd) do
    # revenue is BOTH a strong reward AND real runway
    Autopoet.Integrations.settle_reward(%{source: :market, amount: max(usd, 0.01), target: target})
    safe_earn(usd)
  end

  defp settle(kind, target, value) do
    weight = Map.get(@weights, kind, 0.0)
    if weight > 0.0, do: Autopoet.Integrations.settle_reward(%{source: :market, amount: weight * value, target: target})
  end

  defp safe_earn(usd) do
    Autopoet.Treasury.earn(usd, :market)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp bump(acc, :view, v), do: Map.update!(acc, :views, &(&1 + round(v)))
  defp bump(acc, :signup, v), do: Map.update!(acc, :signups, &(&1 + round(v)))
  defp bump(acc, :revenue, v), do: Map.update!(acc, :revenue_usd, &(&1 + v))
  defp bump(acc, _k, _v), do: acc

  defp no_source, do: []
end
