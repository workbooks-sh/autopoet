defmodule Autopoet.Auth.OAuth do
  @moduledoc """
  Real OAuth for the desktop CONNECT step — the concrete backend behind the
  stubbed `Autopoet.Auth` connect cards. GitHub + Google run the full
  authorization-code flow LOCALLY: the system browser is sent to the provider,
  which redirects back to `http://127.0.0.1:4477/auth/<provider>/callback`; we
  exchange the code for an access token and store it (encrypted) via
  `Autopoet.Connections`. Cloudflare has no consumer OAuth — it's a pasted,
  user-scoped API token we verify and store.

  Credentials are the CLOUD APP's, read via `Nexus.Secrets`
  (`GITHUB_APP_CLIENT_ID/SECRET`, `GOOGLE_OAUTH_CLIENT_ID/SECRET`) — injected
  from the same fly secrets that back wb-dogfood. THE DEV-PHASE CAVEAT: the
  client SECRET lives in the desktop's local env, which is fine for a personal
  install but cannot ship in a distributed binary — the shippable answer is to
  broker the exchange through the cloud app (no secret on device). This module
  is deliberately the one seam that swap touches.

  CSRF: a signed `state` (Phoenix.Token-style via `Plug.Crypto`) carried in a
  cookie and echoed by the provider. Loopback + 127.0.0.1 means no HTTPS, which
  GitHub and Google both permit for localhost redirect URIs.
  """

  import Plug.Conn
  require Logger

  @providers %{
    "github" => %{
      authorize: "https://github.com/login/oauth/authorize",
      token: "https://github.com/login/oauth/access_token",
      scope: "read:user repo",
      id_key: "GITHUB_APP_CLIENT_ID",
      secret_key: "GITHUB_APP_CLIENT_SECRET"
    },
    "google" => %{
      authorize: "https://accounts.google.com/o/oauth2/v2/auth",
      token: "https://oauth2.googleapis.com/token",
      # scope resolved at RUNTIME via scope_env (a @module_attribute would bake
      # System.get_env at COMPILE time — the bug that ignored the env override).
      # Each scope requested must be added to the OAuth consent screen AND its
      # API enabled in the project, or Google rejects it.
      scope_env: "GOOGLE_OAUTH_SCOPE",
      scope:
        "https://www.googleapis.com/auth/drive.readonly " <>
          "https://www.googleapis.com/auth/userinfo.email",
      id_key: "GOOGLE_OAUTH_CLIENT_ID",
      secret_key: "GOOGLE_OAUTH_CLIENT_SECRET"
    },
    # Cloudflare's self-managed OAuth (confidential client). Same OAuth server as
    # Wrangler (dash.cloudflare.com/oauth2), so scopes are Wrangler-style colon
    # form (resource:action). The requested set is env-overridable
    # (CLOUDFLARE_OAUTH_SCOPE) since it must be a subset of what the client was
    # created with — the "enable now" core + offline_access for a refresh token.
    "cloudflare" => %{
      authorize: "https://dash.cloudflare.com/oauth2/auth",
      token: "https://dash.cloudflare.com/oauth2/token",
      # dot-format (permission-group slug + .read/.edit) — confirmed via probing
      # that user-details.read is accepted; the rest mirror the picker's names.
      # env-overridable so a mismatched string is a one-line fix, not a recompile.
      # confirmed valid on the client via probing (login screen reached).
      # NOT on the client (add there, then append here — env-overridable):
      #   cloudflare-pages.edit (publishing) · offline_access (refresh token).
      # the confirmed-valid set (reaches consent). Pages/offline_access are on
      # the client but under scope strings we haven't nailed — resolve them
      # authoritatively from the account once connected, then append here.
      scope_env: "CLOUDFLARE_OAUTH_SCOPE",
      scope: "user-details.read account-settings.read zone.read dns.read account-analytics.read",
      id_key: "CLOUDFLARE_OAUTH_CLIENT_ID",
      secret_key: "CLOUDFLARE_OAUTH_CLIENT_SECRET"
    },
    # OpenRouter — pure PKCE, ZERO registration: the callback_url IS the app
    # identity (no client_id, no secret). The exchange is a JSON POST that
    # returns a user-owned inference `key`, not an access_token. So the agent
    # can use OpenRouter for AI, not only Cloudflare AI Gateway.
    "openrouter" => %{
      style: :openrouter,
      authorize: "https://openrouter.ai/auth",
      token: "https://openrouter.ai/api/v1/auth/keys"
    },
    # Polar.sh — a desktop app is a PUBLIC client: PKCE (S256), no secret. Lets
    # the agent set up monetization (products, checkout links, orders).
    "polar" => %{
      pkce: true,
      authorize: "https://polar.sh/oauth2/authorize",
      token: "https://api.polar.sh/v1/oauth2/token",
      id_key: "POLAR_OAUTH_CLIENT_ID",
      scope_env: "POLAR_OAUTH_SCOPE",
      scope:
        "openid profile email organizations:read " <>
          "products:read products:write checkouts:write checkout_links:read " <>
          "checkout_links:write orders:read subscriptions:read subscriptions:write " <>
          "benefits:read benefits:write customers:read customers:write"
    },
    # Meta (Facebook Login for Business) — ONE connection for the whole Meta
    # business suite: manage organic + ads across Facebook Pages, Instagram, and
    # WhatsApp Business through the Graph + Marketing API. Confidential client
    # (app secret, server-side exchange). The requested scopes reach a user's own
    # accounts in dev mode immediately; customer accounts need App Review
    # (advanced access) + Business Verification — env-overridable so the set can
    # be trimmed to what's been approved without a recompile.
    "meta" => %{
      authorize: "https://www.facebook.com/v21.0/dialog/oauth",
      token: "https://graph.facebook.com/v21.0/oauth/access_token",
      id_key: "META_APP_ID",
      secret_key: "META_APP_SECRET",
      scope_env: "META_OAUTH_SCOPE",
      scope:
        "public_profile email business_management " <>
          "pages_show_list pages_read_engagement pages_manage_posts pages_manage_metadata " <>
          "instagram_basic instagram_content_publish instagram_manage_insights instagram_manage_comments " <>
          "ads_management ads_read read_insights " <>
          "whatsapp_business_management whatsapp_business_messaging"
    },
    # Alpaca (Connect / OAuth) — let the agent trade on a CUSTOMER's brokerage
    # account. For the OPERATOR's own paper/live account use direct API keys
    # (ALPACA_KEY_ID/ALPACA_SECRET_KEY in Secrets, header auth) — no OAuth needed.
    # The Connect flow yields a Bearer token stored in Connections. Finance +
    # trading is the cleanest autonomous oracle: paper P&L is unfakeable.
    "alpaca" => %{
      authorize: "https://app.alpaca.markets/oauth/authorize",
      token: "https://api.alpaca.markets/oauth/token",
      id_key: "ALPACA_OAUTH_CLIENT_ID",
      secret_key: "ALPACA_OAUTH_CLIENT_SECRET",
      scope_env: "ALPACA_OAUTH_SCOPE",
      scope: "account:write trading data"
    }
  }

  @ttl 600
  @state_table :ap_oauth_states

  @doc "Which connect providers can actually run (creds present)?"
  def configured do
    oauth =
      for {name, cfg} <- @providers,
          # openrouter needs no creds; everything else needs its client id present
          cfg[:style] == :openrouter or is_binary(Nexus.Secrets.get(cfg[:id_key])),
          do: name

    # cloudflare also works via the legacy pasted API token, even without OAuth creds
    if "cloudflare" in oauth or is_binary(Nexus.Secrets.get("CLOUDFLARE_API_TOKEN")),
      do: Enum.uniq(["cloudflare" | oauth]),
      else: oauth
  end

  def configured?(provider), do: provider in configured()

  # ── GitHub / Google: system-browser + loopback-callback flow ─────────────────
  # The desktop is a WKWebView; Google rejects OAuth in embedded webviews and
  # window.open won't spawn a real browser there. So the SYSTEM browser runs the
  # flow and redirects to our local callback. CSRF state therefore lives
  # SERVER-SIDE (a short-lived ETS entry), not a cookie — the browser that
  # completes the callback need not be the one that started it.

  @doc "Build the authorize URL + remember its state. nil if the provider isn't configured."
  def authorize_url(conn, provider) do
    case @providers[provider] do
      nil -> nil
      %{style: :openrouter} = cfg -> openrouter_authorize(conn, provider, cfg)
      cfg -> standard_authorize(conn, provider, cfg)
    end
  end

  # OpenRouter: no client_id/scope/response_type; callback_url carries our state
  # so it survives the round trip (OpenRouter echoes back only `code`).
  defp openrouter_authorize(conn, provider, cfg) do
    state = gen_state()
    {verifier, challenge} = pkce_pair()
    remember_state(state, verifier)
    callback = redirect_uri(conn, provider) <> "?state=" <> state

    cfg.authorize <>
      "?" <>
      URI.encode_query(%{
        "callback_url" => callback,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })
  end

  defp standard_authorize(conn, provider, cfg) do
    if is_binary(Nexus.Secrets.get(cfg[:id_key])) do
      state = gen_state()

      {verifier, pkce_params} =
        if cfg[:pkce] do
          {v, c} = pkce_pair()
          {v, %{"code_challenge" => c, "code_challenge_method" => "S256"}}
        else
          {nil, %{}}
        end

      remember_state(state, verifier)

      cfg.authorize <>
        "?" <>
        URI.encode_query(
          %{
            "client_id" => Nexus.Secrets.get(cfg.id_key),
            "redirect_uri" => redirect_uri(conn, provider),
            "scope" => (cfg[:scope_env] && System.get_env(cfg.scope_env)) || cfg.scope,
            "state" => state,
            # GitHub defaults to code; Google REQUIRES it explicitly
            "response_type" => "code"
          }
          |> Map.merge(pkce_params)
          |> Map.merge(extra(provider))
        )
    end
  end

  defp gen_state, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc "GET /auth/:provider/login — 302 to the provider (dev / same-browser path)."
  def login(conn, provider) do
    case authorize_url(conn, provider) do
      nil -> send_resp(conn, 404, "#{provider} not configured\n")
      url -> conn |> put_resp_header("location", url) |> send_resp(302, "")
    end
  end

  @doc "Open the provider's login in the host's SYSTEM browser (the desktop path)."
  def open_login(conn, provider) do
    case authorize_url(conn, provider) do
      nil ->
        {:error, :not_configured}

      url ->
        System.cmd("open", [url])
        :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Google wants offline access + a consent prompt to actually return a refresh token
  defp extra("google"), do: %{"access_type" => "offline", "prompt" => "consent"}
  defp extra(_), do: %{}

  @doc "GET /auth/:provider/callback — verify state, exchange, store, close the tab."
  def callback(conn, provider) do
    conn = fetch_query_params(conn)
    cfg = @providers[provider]
    p = conn.query_params

    with true <- cfg != nil,
         state when is_binary(state) <- p["state"],
         {:ok, verifier} <- consume_state(state),
         code when is_binary(code) and code != "" <- p["code"],
         {:ok, token} <- exchange(provider, cfg, code, redirect_uri(conn, provider), verifier) do
      Autopoet.Connections.put(provider, token)
      Autopoet.Auth.connect(provider)
      Nexus.Events.emit(%{kind: "connection.linked", provider: provider, tags: []})
      Autopoet.Log.puts("oauth: #{provider} connected")
      close_tab(conn, provider, :ok)
    else
      _ ->
        Autopoet.Log.puts("oauth: #{provider} callback refused")
        close_tab(conn, provider, :error)
    end
  end

  # OpenRouter: JSON POST, returns a user-owned inference key (not access_token)
  defp exchange(_provider, %{style: :openrouter} = cfg, code, _redirect, verifier) do
    body = Jason.encode!(%{"code" => code, "code_verifier" => verifier, "code_challenge_method" => "S256"})
    headers = [{~c"accept", ~c"application/json"}, {~c"content-type", ~c"application/json"}]
    :inets.start()
    :ssl.start()

    case :httpc.request(:post, {String.to_charlist(cfg.token), headers, ~c"application/json", String.to_charlist(body)}, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case Jason.decode(to_string(resp)) do
          {:ok, %{"key" => key}} when is_binary(key) -> {:ok, key}
          _ -> {:error, :no_key}
        end

      other ->
        Logger.warning("openrouter exchange: #{inspect(other)}")
        {:error, :exchange_failed}
    end
  end

  defp exchange(provider, cfg, code, redirect_uri, verifier) do
    base = %{
      "client_id" => Nexus.Secrets.get(cfg.id_key),
      "code" => code,
      "redirect_uri" => redirect_uri,
      "grant_type" => "authorization_code"
    }

    # PKCE public clients send code_verifier and NO secret; confidential clients
    # send the secret. A provider may carry both (PKCE + confidential).
    params =
      base
      |> then(fn m -> if verifier, do: Map.put(m, "code_verifier", verifier), else: m end)
      |> then(fn m ->
        case cfg[:secret_key] && Nexus.Secrets.get(cfg.secret_key) do
          s when is_binary(s) -> Map.put(m, "client_secret", s)
          _ -> m
        end
      end)

    form = URI.encode_query(params)
    headers = [{~c"accept", ~c"application/json"}, {~c"content-type", ~c"application/x-www-form-urlencoded"}]
    :inets.start()
    :ssl.start()

    case :httpc.request(:post, {String.to_charlist(cfg.token), headers, ~c"application/x-www-form-urlencoded", String.to_charlist(form)}, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, :no_token}
        end

      other ->
        Logger.warning("oauth exchange #{provider}: #{inspect(other)}")
        {:error, :exchange_failed}
    end
  end

  # ── Cloudflare: paste + verify a scoped API token ────────────────────────────

  @doc "Verify a pasted Cloudflare API token against the CF API; store on success."
  def cloudflare_connect(token) when is_binary(token) do
    token = String.trim(token)

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/json"}
    ]

    url = ~c"https://api.cloudflare.com/client/v4/user/tokens/verify"
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {url, headers}, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"success" => true}} ->
            Autopoet.Connections.put("cloudflare", token)
            Autopoet.Auth.connect("cloudflare")
            Nexus.Events.emit(%{kind: "connection.linked", provider: "cloudflare", tags: []})
            Autopoet.Log.puts("oauth: cloudflare token verified + connected")
            :ok

          _ ->
            {:error, :invalid_token}
        end

      # CF returns 401 for a malformed/invalid token — that's a bad token, not
      # a transport failure; say so honestly
      {:ok, {{_, code, _}, _, _}} when code in [400, 401, 403] ->
        {:error, :invalid_token}

      other ->
        Logger.warning("cloudflare verify: #{inspect(other)}")
        {:error, :verify_failed}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp redirect_uri(conn, provider) do
    port = conn.port
    "http://127.0.0.1:#{port}/auth/#{provider}/callback"
  end

  # server-side CSRF state: a short-lived, single-use nonce set. Survives across
  # browsers (system-browser flow) where a cookie could not.
  defp table do
    case :ets.whereis(@state_table) do
      :undefined -> :ets.new(@state_table, [:named_table, :public, :set])
      _ -> @state_table
    end
  end

  # PKCE flows stash their code_verifier alongside the state (the callback needs
  # it for the token exchange); classic flows pass nil.
  defp remember_state(state, verifier \\ nil), do: :ets.insert(table(), {state, now(), verifier})

  # returns {:ok, verifier} for a fresh single-use state (verifier nil if non-PKCE)
  defp consume_state(state) do
    case :ets.take(table(), state) do
      [{^state, ts, verifier}] -> if now() - ts <= @ttl, do: {:ok, verifier}, else: :error
      _ -> :error
    end
  end

  # PKCE (RFC 7636): a high-entropy verifier + its S256 challenge
  defp pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp now, do: System.os_time(:second)

  # the callback tab: a tiny self-closing page so the browser doesn't linger
  defp close_tab(conn, provider, status) do
    msg = if status == :ok, do: "#{provider} connected — you can close this tab.", else: "#{provider} connection failed."

    html = """
    <!doctype html><meta charset=utf-8>
    <body style="font:14px ui-monospace,monospace;color:#1c2230;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
    <div style="text-align:center">
      <p>#{msg}</p>
      <script>
        try { window.opener && window.opener.postMessage({apOauth:"#{provider}",ok:#{status == :ok}}, "*"); } catch(e){}
        setTimeout(() => window.close(), 800);
      </script>
    </div></body>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end
end
