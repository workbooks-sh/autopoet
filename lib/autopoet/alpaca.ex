defmodule Autopoet.Alpaca do
  @moduledoc """
  The Alpaca trading lane (v3, wb-siutv) — the autopoet's cleanest autonomous
  oracle: it trades a PAPER account and the P&L is unfakeable, immediate, and
  quantitative. Market data + research in, a risk-bounded order out, realized
  P&L back as reward (`Autopoet.Market`), all gated by `Autopoet.Treasury`.

  Two auth models, both supported:
    * DIRECT (paper/live) — the agent trades ITS OWN account with an API key +
      secret (`APCA-API-KEY-ID` / `APCA-API-SECRET-KEY` headers). Paper by
      default; nothing costs money.
    * OAUTH (Connect) — acting on a CUSTOMER's Alpaca account via a connected
      OAuth token (Bearer). Added as a Connections provider like Meta.

  Every function takes an INJECTABLE transport (`:transport`) so the whole lane
  is eval-driven without live calls; the same code runs live when keys/tokens
  are present. Reads keys from `Autopoet.Connections` (provider `alpaca`) or
  opts; base URL defaults to the PAPER endpoint.

  RISK BOUNDARY: `place_order/1` refuses any order whose notional exceeds the
  per-order cap (`:max_notional`, default $10k of paper) OR — for real money —
  what `Autopoet.Treasury` allows. The autopoet cannot YOLO the account.
  """

  @paper "https://paper-api.alpaca.markets/v2"
  @live "https://api.alpaca.markets/v2"
  @data "https://data.alpaca.markets/v2"
  @default_max_notional 10_000.0

  # ── account / positions / clock ─────────────────────────────────────────────

  @doc "The account snapshot (cash, buying_power, equity, status). `{:ok, map} | {:error, _} | {:skip, :not_connected}`."
  def account(opts \\ []), do: get("/account", opts)

  @doc "Open positions (symbol, qty, market_value, unrealized_pl)."
  def positions(opts \\ []), do: get("/positions", opts)

  @doc "Market clock — is the market open right now?"
  def clock(opts \\ []), do: get("/clock", opts)

  @doc "Recent bars (OHLCV) for `symbol` — the market DATA the decision rests on. `opts[:timeframe]` (default 1Day), `opts[:limit]`."
  def bars(symbol, opts \\ []) do
    tf = Keyword.get(opts, :timeframe, "1Day")
    limit = Keyword.get(opts, :limit, 30)
    get("/stocks/#{symbol}/bars?timeframe=#{tf}&limit=#{limit}", Keyword.put(opts, :base, @data))
  end

  # ── the risk-bounded order (the cage applies to trading too) ────────────────

  @doc """
  Place an order. `order` = `%{symbol, qty, side: :buy | :sell, type: :market |
  :limit, ...}`. REFUSES if the order's notional exceeds `:max_notional`
  (paper risk cap) or the Treasury's real-money allowance. Returns
  `{:ok, order} | {:error, reason} | {:skip, :not_connected}`.
  """
  def place_order(order, opts \\ []) do
    notional = order_notional(order, opts)
    cap = Keyword.get(opts, :max_notional, @default_max_notional)

    cond do
      notional > cap ->
        {:error, {:over_risk_cap, notional, cap}}

      Keyword.get(opts, :real_money, false) and treasury_refuses?(notional) ->
        {:error, :treasury_refused}

      true ->
        body = %{
          "symbol" => to_string(order[:symbol]),
          "qty" => to_string(order[:qty]),
          "side" => to_string(order[:side] || :buy),
          "type" => to_string(order[:type] || :market),
          "time_in_force" => to_string(order[:time_in_force] || :day)
        }

        post("/orders", body, opts)
    end
  end

  @doc "Estimate an order's USD notional from qty × a reference price (`order[:price]` or opts[:price])."
  def order_notional(order, opts \\ []) do
    qty = to_number(order[:qty] || 0)
    price = to_number(order[:price] || Keyword.get(opts, :price, 0))
    abs(qty * price) * 1.0
  end

  # ── HTTP (injectable) ───────────────────────────────────────────────────────

  defp get(path, opts), do: request(:get, path, nil, opts)
  defp post(path, body, opts), do: request(:post, path, body, opts)

  defp request(method, path, body, opts) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 3) ->
        fun.(method, path, body)

      _ ->
        creds = creds(opts)

        if creds == nil do
          {:skip, :not_connected}
        else
          live_request(method, base(opts) <> path, body, creds)
        end
    end
  end

  # key+secret (direct) or bearer token (oauth) — from opts or Connections
  defp creds(opts) do
    cond do
      opts[:key] && opts[:secret] -> {:keypair, opts[:key], opts[:secret]}
      opts[:token] -> {:bearer, opts[:token]}
      (t = connected_token()) -> {:bearer, t}
      (kp = connected_keypair()) -> kp
      true -> nil
    end
  end

  defp connected_token do
    try do
      Autopoet.Connections.get("alpaca")
    rescue
      _ -> nil
    end
  end

  # direct paper/live keys live in Secrets (ALPACA_KEY_ID / ALPACA_SECRET_KEY)
  defp connected_keypair do
    with k when is_binary(k) <- Nexus.Secrets.get("ALPACA_KEY_ID"),
         s when is_binary(s) <- Nexus.Secrets.get("ALPACA_SECRET_KEY") do
      {:keypair, k, s}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp base(opts) do
    cond do
      opts[:base] -> opts[:base]
      Keyword.get(opts, :live, false) -> @live
      true -> @paper
    end
  end

  defp headers({:keypair, k, s}), do: [{~c"APCA-API-KEY-ID", cl(k)}, {~c"APCA-API-SECRET-KEY", cl(s)}, {~c"accept", ~c"application/json"}]
  defp headers({:bearer, t}), do: [{~c"authorization", cl("Bearer " <> t)}, {~c"accept", ~c"application/json"}]

  defp live_request(method, url, body, creds) do
    :inets.start()
    :ssl.start()
    h = headers(creds)

    req =
      case method do
        :get -> {cl(url), h}
        :post -> {cl(url), h, ~c"application/json", cl(Jason.encode!(body || %{}))}
      end

    case :httpc.request(method, req, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, code, _}, _, resp}} when code in 200..299 -> {:ok, Jason.decode!(to_string(resp))}
      {:ok, {{_, code, _}, _, resp}} -> {:error, {:http, code, String.slice(to_string(resp), 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp treasury_refuses?(notional) do
    match?({:error, _}, Autopoet.Treasury.charge(notional, "trade_risk", "alpaca"))
  rescue
    _ -> true
  end

  defp cl(s), do: String.to_charlist(to_string(s))
  defp to_number(n) when is_number(n), do: n
  defp to_number(s) when is_binary(s), do: case Float.parse(s), do: ({f, _} -> f; :error -> 0)
  defp to_number(_), do: 0
end
