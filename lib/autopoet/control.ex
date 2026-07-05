defmodule Autopoet.Control do
  @moduledoc """
  Localhost-only control surface (bound to 127.0.0.1 by the supervisor).

    GET  /         the white page — debug log tailing over SSE
    GET  /status   plain-text status (armed, memory, uptime, last cycle)
    GET  /log      last 200 log lines
    GET  /sse      the live log stream
    POST /arm      arm the autopoet heartbeat  (?every=15m)   [token]
    POST /disarm   disarm the heartbeat                       [token]
    POST /close    close the window — same handler as the stoplight [token]
    POST /kill     halt the BEAM                              [token]

  Mutating routes require the per-boot bearer token from `data/ctl`. Responses are
  plain text — no JSON.
  """
  use Plug.Router

  alias Autopoet.Log

  plug :match
  plug :dispatch

  get "/" do
    html =
      [:code.priv_dir(:autopoet), "static", "app.html"]
      |> Path.join()
      |> File.read!()
      |> String.replace("__TOKEN__", Autopoet.Discovery.token())
      |> String.replace("__CHROME__", if(Autopoet.Window.frameless?(), do: "flex", else: "none"))

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, html)
  end

  get "/static/d3.v7.min.js" do
    js = [:code.priv_dir(:autopoet), "static", "d3.v7.min.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  get "/static/lucide.min.js" do
    js = [:code.priv_dir(:autopoet), "static", "lucide.min.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  get "/static/gsap.min.js" do
    js = [:code.priv_dir(:autopoet), "static", "gsap.min.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  # the nexus-setup quiz — deliberately its OWN file, not another app.html inline
  get "/static/quiz.js" do
    js = [:code.priv_dir(:autopoet), "static", "quiz.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  # interactive plan mode (docs/interactive-plan-mode.md) — own file, lazy-loaded
  # only when entering plan mode (elk is 1.5MB; don't tax every boot)
  get "/static/planmode.js" do
    js = [:code.priv_dir(:autopoet), "static", "planmode.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  get "/static/elk.bundled.js" do
    js = [:code.priv_dir(:autopoet), "static", "elk.bundled.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  # the quiz's industry corpus — data, not code, so it swaps without touching quiz.js
  get "/static/quiz-corpus.js" do
    js = [:code.priv_dir(:autopoet), "static", "quiz-corpus.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  # the proposal-first entry overlay (Lane D) — its own file, like the quiz
  get "/static/intake.js" do
    js = [:code.priv_dir(:autopoet), "static", "intake.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  get "/static/perfect-freehand.mjs" do
    js = [:code.priv_dir(:autopoet), "static", "perfect-freehand.mjs"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("text/javascript") |> send_resp(200, js)
  end

  # portraits for the onboarding "built on science" slide (Wikimedia Commons, attributed)
  get "/static/people/:name" do
    path = Path.join([:code.priv_dir(:autopoet), "static", "people", Path.basename(name)])

    if File.exists?(path) and Path.extname(name) in [".png", ".jpg"] do
      type = if String.ends_with?(name, ".png"), do: "image/png", else: "image/jpeg"
      conn |> put_resp_content_type(type) |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no portrait\n")
    end
  end

  # the lottie player + quiz-card animations (owned IconScout packs, see LICENSE.txt)
  get "/static/lottie.min.js" do
    js = [:code.priv_dir(:autopoet), "static", "lottie.min.js"] |> Path.join() |> File.read!()
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, js)
  end

  get "/static/lotties/:name" do
    path = Path.join([:code.priv_dir(:autopoet), "static", "lotties", Path.basename(name)])

    if File.exists?(path) and String.ends_with?(name, ".json") do
      conn |> put_resp_content_type("application/json") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no animation\n")
    end
  end

  get "/static/micons/:name" do
    path = Path.join([:code.priv_dir(:autopoet), "static", "micons", Path.basename(name)])

    if File.exists?(path) and String.ends_with?(name, ".svg") do
      conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no icon\n")
    end
  end

  # the full VS Code Material icon set as names — powers the icon picker's search
  get "/micons.json" do
    dir = Path.join([:code.priv_dir(:autopoet), "static", "micons"])

    names =
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".svg"))
          |> Enum.map(&String.trim_trailing(&1, ".svg"))
          |> Enum.sort()

        _ ->
          []
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(names))
  end

  get "/favicon.ico" do
    conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, Autopoet.Avatar.svg(Autopoet.Avatar.default_seed(), 32))
  end

  get "/notes/tree.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.Notes.tree()))
  end

  get "/notes/file" do
    conn = fetch_query_params(conn)

    case Autopoet.Notes.read(conn.query_params["path"] || "") do
      {:ok, content} -> text(conn, content)
      _ -> send_resp(conn, 404, "no such note\n")
    end
  end

  # ── body files (.work): the human is sovereign — direct edits from the UI
  # pencil bypass no gate because the gate constrains the MACHINE, not you ────

  get "/body/file" do
    conn = fetch_query_params(conn)

    case File.read(body_path!(conn.query_params["path"])) do
      {:ok, content} -> text(conn, content)
      _ -> send_resp(conn, 404, "no such file\n")
    end
  end

  post "/body/save" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 10_000_000)
      # the human editing the body via the pencil is ALSO a direct write — snapshot it
      # to the same history so it's undoable alongside the agent's writes.
      Autopoet.Body.write(conn.query_params["path"], body)
      Autopoet.Log.puts("body: human edited #{conn.query_params["path"]} directly")
      text(conn, "saved\n")
    end)
  end

  # the body's change history + undo/redo (agent writes .work directly; nothing is
  # unrecoverable, and any edit is reversible in both directions)
  get "/body/history.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.Body.history()))
  end

  get "/body/undostate.json" do
    state = %{undo: Autopoet.Body.can_undo?(), redo: Autopoet.Body.can_redo?()}
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(state))
  end

  post "/body/undo" do
    authed!(conn, fn conn ->
      id = conn.query_params["id"] || :latest
      _ = Autopoet.Body.undo(id)
      undo_state(conn)
    end)
  end

  post "/body/redo" do
    authed!(conn, fn conn ->
      _ = Autopoet.Body.redo()
      undo_state(conn)
    end)
  end

  # ── auth / onboarding (stub provider now; a real one slots in behind Autopoet.Auth) ──
  get "/auth/state.json" do
    s = Autopoet.Auth.state()

    # real, token-backed connections are the source of truth; the session's
    # stub map only carries providers connected before real OAuth existed
    real = Map.new(Autopoet.Connections.all(), &{&1, true})

    body = %{
      authenticated: s.authenticated,
      onboarded: s.onboarded,
      user: s.user,
      connections: Map.merge(Map.get(s, :connections, %{}), real)
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  post "/auth/signin" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.signin(conn.query_params) do
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
        _ -> text(conn, "app\n")
      end
    end)
  end

  post "/auth/signup" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.signup(conn.query_params) do
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
        _ -> text(conn, "onboarding\n")
      end
    end)
  end

  # the splash's one door — GitHub/Google, stubbed behind the provider seam.
  # Replies "app" (returning, onboarded) or "onboarding" (fresh) so the client routes.
  post "/auth/oauth/:provider" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.oauth(provider, conn.query_params) do
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
        %{onboarded: true} -> text(conn, "app\n")
        _ -> text(conn, "onboarding\n")
      end
    end)
  end

  # connect / disconnect a provider from onboarding's connect cards (stub)
  post "/auth/connect/:provider" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.connect(provider) do
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
        _ -> text(conn, "ok\n")
      end
    end)
  end

  post "/auth/disconnect/:provider" do
    authed!(conn, fn conn ->
      Autopoet.Connections.delete(provider)

      case Autopoet.Auth.disconnect(provider) do
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
        _ -> text(conn, "ok\n")
      end
    end)
  end

  # ── Workbooks Cloud sign-in (browser device flow) ────────────────────────────
  # MUST come before the /auth/:provider/* wildcards below, or "cloud" is captured
  # as an OAuth provider and refused (:not_configured). Plug matches in source order.
  post "/auth/cloud/open" do
    cb = "http://127.0.0.1:#{conn.port}/auth/cloud/callback"
    url = Autopoet.Cloud.base_url() <> "/login/?device=autopoet&cb=" <> URI.encode_www_form(cb)
    spawn(fn -> System.cmd("open", [url]) end)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  # ── onboarding POWER gate: how the agent gets its AI ─────────────────────────
  # CLOUD (paid) → open the dashboard to provision a machine (AI via the gateway).
  # LOCAL (free) → save a bring-your-own OpenRouter key. One is required to run.
  post "/power/cloud/open" do
    spawn(fn -> System.cmd("open", [Autopoet.Cloud.base_url() <> "/cloud/"]) end)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  post "/power/openrouter" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn)
      key = String.trim(body)

      if key == "" do
        conn |> put_resp_content_type("application/json") |> send_resp(422, Jason.encode!(%{error: "empty key"}))
      else
        Autopoet.Keys.set_openrouter(key)
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
      end
    end)
  end

  # is the agent powered? — an ACTIVE machine subscription, an EXISTING nexus
  # (already provisioned on the account), or a local key.
  # The two cloud reads run CONCURRENTLY (5s cap each, crash-safe) behind a ~30s
  # micro-cache, so the onboarding prefetch + pollPowered's 2.5s polling don't
  # hammer the control plane. Response shape is unchanged.
  @power_cache_key {__MODULE__, :power_status_cache}
  @power_cache_ms 30_000

  get "/power/status" do
    {sub, nexuses} = cloud_power_state()

    # two separate axes: COMPUTE (where it runs — chosen in step 1, persisted)
    # and INFERENCE (how it thinks — gateway via cloud, or a local key).
    compute =
      case File.read(Path.join([Autopoet.Discovery.home(), "data", "power-compute"])) do
        {:ok, c} -> String.trim(c)
        _ -> nil
      end

    # a cloud machine (sub or existing nexus) carries gateway AI; a key is the
    # local lane — either satisfies inference
    inference = sub != nil or nexuses != [] or is_binary(Autopoet.Keys.openrouter())
    powered = inference

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        powered: powered,
        compute: compute,
        inference: inference,
        openrouter: is_binary(Autopoet.Keys.openrouter()),
        subscription: sub,
        nexuses: nexuses
      })
    )
  end

  # {subscription, nexuses} — both cloud calls in parallel, micro-cached.
  # A failed read caches only briefly (5s) so a retry goes live again.
  defp cloud_power_state do
    now = System.system_time(:millisecond)

    case :persistent_term.get(@power_cache_key, nil) do
      {state, ts, ttl} when now - ts < ttl ->
        state

      _ ->
        sub_task = Task.async(fn -> cloud_sub_safe() end)
        nex_task = Task.async(fn -> cloud_nexuses_safe() end)
        sub_r = power_task_get(sub_task)
        nex_r = power_task_get(nex_task)

        sub =
          case sub_r do
            {:ok, s} -> s
            :error -> nil
          end

        nexuses =
          case nex_r do
            {:ok, l} -> l
            :error -> []
          end

        state = {sub, nexuses}
        ok? = sub_r != :error and nex_r != :error
        :persistent_term.put(@power_cache_key, {state, now, if(ok?, do: @power_cache_ms, else: 5_000)})
        state
    end
  end

  defp power_task_get(task) do
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, v} -> v
      _ -> :error
    end
  end

  defp cloud_sub_safe do
    case Autopoet.Cloud.get("/api/platform/billing/subscription") do
      {:ok, %{"status" => "active"} = s} -> {:ok, s}
      {:ok, _} -> {:ok, nil}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp cloud_nexuses_safe do
    case Autopoet.Cloud.get("/api/platform/nexuses") do
      {:ok, %{"nexuses" => l}} when is_list(l) -> {:ok, l}
      {:ok, l} when is_list(l) -> {:ok, l}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # the account's existing nexuses — the "use the one you already have" lane
  get "/power/cloud/nexuses", do: cloud_proxy(conn, :get, "/api/platform/nexuses", nil)

  # ── the COMPUTE choice (step 1: where it runs) — separate from inference ──
  # modes: "nexus <id>" (existing) | "cloud-new <plan>" (bought) | "local"
  post "/power/compute" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn)
      choice = body |> String.trim() |> String.slice(0, 120)

      if choice == "" do
        send_resp(conn, 422, "compute choice required\n")
      else
        path = Path.join([Autopoet.Discovery.home(), "data", "power-compute"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, choice <> "\n")
        text(conn, "compute set\n")
      end
    end)
  end

  # ── inline Workbooks Cloud billing (proxied to the cloud via the signed-in PAT,
  # so the machine purchase happens IN the app, not by bouncing to the dashboard).
  # Same card (external_customer_id=org) across machine, credits, auto-top-up. ────
  get "/power/cloud/tiers", do: cloud_proxy(conn, :get, "/api/platform/tiers", nil)

  get "/power/cloud/summary" do
    payload = %{
      credits: cloud_get_or("/api/platform/credits", %{}),
      autotopup: cloud_get_or("/api/platform/billing/autotopup", %{}),
      subscription: cloud_get_or("/api/platform/billing/subscription", %{})
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
  end

  post "/power/cloud/checkout" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn)
      cloud_proxy(conn, :post, "/api/platform/billing/checkout", body)
    end)
  end

  post "/power/cloud/credits" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn)
      cloud_proxy(conn, :post, "/api/platform/credits/checkout", body)
    end)
  end

  post "/power/cloud/autotopup" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn)
      cloud_proxy(conn, :post, "/api/platform/billing/autotopup", body)
    end)
  end

  # open-in-browser fallback for the inline checkout (if the provider blocks framing)
  post "/power/cloud/openurl" do
    {:ok, url, conn} = read_body(conn)
    if String.starts_with?(url, "https://"), do: spawn(fn -> System.cmd("open", [url]) end)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  # The cloud redirects here with the minted PAT; store it and confirm in the tab (which pings the opener).
  get "/auth/cloud/callback" do
    conn = fetch_query_params(conn)

    case Autopoet.Cloud.put_token(conn.query_params["token"] || "") do
      :ok ->
        # the cloud PAT is the app's front door: establish the local session
        # from the cloud identity so "Sign in with Workbooks" IS the sign-in
        Autopoet.Auth.sign_in_cloud()

        page = """
        <!doctype html><meta charset="utf-8"><title>Connected</title>
        <body style="font:15px system-ui;display:grid;place-items:center;height:100vh;margin:0;color:#16161a">
        <div style="text-align:center"><h2>Connected to Workbooks Cloud ✓</h2><p style="color:#6a6f68">You can close this tab.</p></div>
        <script>try{if(window.opener)window.opener.postMessage({apCloud:true},'*')}catch(e){};setTimeout(function(){window.close()},1200)</script>
        """

        conn |> put_resp_content_type("text/html") |> send_resp(200, page)

      _ ->
        conn |> put_resp_content_type("text/html") |> send_resp(400, "<p>Sign-in failed — no token received.</p>")
    end
  end

  # FULL sign-out — the one clean seam: revoke + drop the cloud PAT, clear the
  # local app session, and hand back the browser logout URL so the caller can
  # clear the cloud cookie too (a truly fresh re-login shows the password form).
  post "/auth/cloud/signout" do
    authed!(conn, fn conn ->
      Autopoet.Cloud.sign_out()
      Autopoet.Auth.signout()
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, logout_url: Autopoet.Cloud.logout_url()}))
    end)
  end

  post "/auth/cloud/disconnect" do
    authed!(conn, fn conn ->
      Autopoet.Cloud.disconnect()
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
    end)
  end

  # ── real OAuth (github/google browser flow; cloudflare token paste) ──────────
  # These are BROWSER navigations (the system browser follows the redirect), so
  # they are NOT bearer-authed — CSRF state protects the round trip instead.
  get "/auth/:provider/login" do
    Autopoet.Auth.OAuth.login(conn, provider)
  end

  get "/auth/:provider/callback" do
    Autopoet.Auth.OAuth.callback(conn, provider)
  end

  # the desktop path: open the login in the host's SYSTEM browser (WKWebView can't
  # host Google's OAuth). The UI then polls /auth/state.json for the connection.
  post "/auth/:provider/open" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.OAuth.open_login(conn, provider) do
        :ok -> text(conn, "opened\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # cloudflare has no consumer OAuth — verify + store a pasted, user-scoped token
  post "/auth/cloudflare/token" do
    authed!(conn, fn conn ->
      case Autopoet.Auth.OAuth.cloudflare_connect(conn.query_params["token"] || "") do
        :ok -> text(conn, "ok\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # which providers can actually run a real connect (creds present)
  get "/auth/providers.json" do
    body = %{configured: Autopoet.Auth.OAuth.configured(), connected: Autopoet.Connections.all()}
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  # ── Workbooks Cloud: the agent's toolbelt (Composio) + cloud host (control plane) ──
  # Composio is live now (local key); cloud hosting is the control-plane build.
  get "/cloud/toolkits" do
    conn = fetch_query_params(conn)

    opts =
      [limit: conn.query_params["limit"] || "40"] ++
        case conn.query_params["search"] do
          s when is_binary(s) and s != "" -> [search: s]
          _ -> []
        end

    case Autopoet.Composio.toolkits(opts) do
      {:ok, body} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
      {:skip, _} -> send_resp(conn, 503, "composio not configured\n")
      {:error, r} -> send_resp(conn, 502, "composio error: #{inspect(r)}\n")
    end
  end

  # start connecting a toolkit → returns the redirect_url the user completes
  post "/cloud/connect/:toolkit" do
    authed!(conn, fn conn ->
      case Autopoet.Composio.connect(toolkit) do
        {:ok, %{redirect_url: url}} -> text(conn, url)
        {:skip, _} -> send_resp(conn, 503, "composio not configured\n")
        {:error, r} -> send_resp(conn, 502, "connect failed: #{inspect(r)}\n")
      end
    end)
  end

  # readiness of the Workbooks Cloud halves — sign-in, toolbelt, cloud host — the card reflects this honestly
  get "/cloud/status.json" do
    signed = Autopoet.Cloud.signed_in?()
    acct = signed && Autopoet.Cloud.account()

    body = %{
      signed_in: signed,
      account: acct && %{email: acct.email, org: acct.org, role: acct.role},
      tools: Autopoet.Composio.configured?(),
      host: cloud_host_ready?()
    }

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  # ── Deploy pipeline: run this AutoPoet as a dedicated cloud machine ───────────────────────────────
  # Provision → the control plane clones the autopoet Fly image into your machine. Needs sign-in first.
  post "/cloud/deploy" do
    authed!(conn, fn conn ->
      case Autopoet.Cloud.post("/api/cloud/provision", %{}) do
        {:ok, body} -> conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
        {:error, :not_signed_in} -> send_resp(conn, 401, "sign in to workbooks cloud first\n")
        {:error, {code, body}} when is_integer(code) -> conn |> put_resp_content_type("application/json") |> send_resp(code, Jason.encode!(body))
        {:error, e} -> send_resp(conn, 502, "deploy failed: #{inspect(e)}\n")
      end
    end)
  end

  # Your cloud machine's live status (for the deploy panel to poll).
  get "/cloud/machine.json" do
    body =
      case Autopoet.Cloud.get("/api/cloud/machine") do
        {:ok, b} -> b
        {:error, {_code, b}} when is_map(b) -> b
        {:error, :not_signed_in} -> %{"error" => "not signed in"}
        _ -> %{"error" => "unavailable"}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  get "/cloud/connections.json" do
    body =
      case Autopoet.Composio.connections() do
        {:ok, b} -> b
        _ -> %{"items" => []}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  # ── setup profile: the quiz's answers, read back by the brain for personalization ──
  post "/profile/set" do
    authed!(conn, fn conn ->
      case Autopoet.Profile.put(conn.query_params["key"], conn.query_params["value"]) do
        :ok -> text(conn, "ok\n")
        _ -> text(conn, "refused: bad answer\n")
      end
    end)
  end

  get "/profile" do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, Autopoet.Profile.render())
  end

  post "/profile/reset" do
    authed!(conn, fn conn ->
      Autopoet.Profile.clear()
      text(conn, "ok\n")
    end)
  end

  post "/auth/onboarding/done" do
    authed!(conn, fn conn ->
      Autopoet.Auth.complete_onboarding()
      # belt-and-suspenders: the quiz finale already kicks the intake; if the
      # user sprinted past it, this is the last safe moment (marker-guarded)
      Autopoet.Intake.start()
      text(conn, "app\n")
    end)
  end

  # DEV: restart onboarding (owner's plan-mode test loop). ?full=1 also signs
  # out → the whole door→sign-in→onboarding sequence from the top.
  post "/auth/onboarding/reset" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)
      Autopoet.Auth.reset_onboarding()
      if conn.query_params["full"] == "1", do: Autopoet.Auth.signout()
      text(conn, "onboarding reset\n")
    end)
  end

  # ── the intake agent: builds the first world while the finale is on screen ──
  post "/intake/start" do
    authed!(conn, fn conn -> text(conn, "#{Autopoet.Intake.start()}\n") end)
  end

  # the pending first proposal, if any: line 1 = id, rest = the brief (plain text)
  get "/intake/proposal" do
    case Autopoet.Intake.pending_proposal() do
      nil -> send_resp(conn, 404, "none\n")
      {id, brief} -> text(conn, id <> "\n" <> brief)
    end
  end

  post "/auth/signout" do
    authed!(conn, fn conn -> Autopoet.Auth.signout(); text(conn, "out\n") end)
  end

  # ── AI clustering: the human describes a grouping; the model assigns graph nodes
  # to named clusters. Line-based reply (= Name / one id per line), parsed here. ──
  post "/graph/cluster" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 200_000)
      [prompt | lines] = String.split(body, "\n")
      catalog = Enum.join(lines, "\n")

      system = """
      You group graph nodes into named clusters. The user gives a grouping request and a
      node catalog (one per line: id ⇥ type ⇥ label). Reply ONLY with groups in this form:

      = Group Name
      node-id
      node-id

      Every group needs at least one node id copied EXACTLY from the catalog. Nodes that
      don't fit any group are simply omitted. No prose, no explanations.
      """

      case Autopoet.Chat.oneshot(system, "REQUEST: #{prompt}\n\nCATALOG:\n#{catalog}") do
        {:ok, text} ->
          groups =
            text
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reduce([], fn
              "= " <> name, acc -> [%{name: String.trim(name), members: []} | acc]
              "", acc -> acc
              id, [g | rest] -> [%{g | members: [id | g.members]} | rest]
              _, [] -> []
            end)
            |> Enum.reverse()
            |> Enum.map(fn g -> %{g | members: Enum.reverse(g.members)} end)
            |> Enum.reject(fn g -> g.members == [] end)

          conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{clusters: groups}))

        {:error, reason} ->
          conn |> put_resp_content_type("application/json")
               |> send_resp(200, Jason.encode!(%{error: inspect(reason)}))
      end
    end)
  end

  # ── the version-control timeline (jj repo at data/history) — the console's
  # history manager reads the REAL commit DAG from here ───────────────────────
  get "/history/log.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.History.log()))
  end

  # what one commit changed — the inspect panel's "what happened here" file list
  get "/history/diff.json" do
    conn = fetch_query_params(conn)
    files = Autopoet.History.diff(conn.query_params["rev"] || "@")
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{files: files}))
  end

  post "/history/merge" do
    authed!(conn, fn conn ->
      case Autopoet.History.merge_heads() do
        {:ok, n} -> text(conn, "merged #{n} heads\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/history/restore" do
    authed!(conn, fn conn ->
      case Autopoet.History.restore(conn.query_params["rev"] || "") do
        {:ok, n} -> text(conn, "restored #{n} vault file(s)\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # proxy a call to Workbooks Cloud through the signed-in PAT, passing the cloud's
  # JSON response (and status) straight back to the inline billing UI.
  defp cloud_proxy(conn, method, path, raw) do
    result =
      case method do
        :get -> Autopoet.Cloud.get(path)
        :post -> Autopoet.Cloud.post(path, decode_json(raw))
      end

    {status, payload} =
      case result do
        {:ok, data} -> {200, data}
        {:error, {code, data}} when is_integer(code) -> {code, data}
        {:error, :not_signed_in} -> {401, %{error: "not signed in to Workbooks Cloud"}}
        {:error, reason} -> {502, %{error: "cloud unreachable", detail: inspect(reason)}}
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload))
  end

  defp cloud_get_or(path, default) do
    case Autopoet.Cloud.get(path) do
      {:ok, v} -> v
      _ -> default
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw || "") do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  defp body_path!(rel) do
    rel = to_string(rel)

    if String.starts_with?(rel, "/") or String.contains?(rel, ".."),
      do: raise(ArgumentError, "unsafe path: #{rel}")

    Path.join(Nexus.Paths.data_dir(), rel)
  end

  # after an undo/redo, hand back the fresh availability so the UI buttons re-enable
  defp undo_state(conn) do
    state = %{undo: Autopoet.Body.can_undo?(), redo: Autopoet.Body.can_redo?()}
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(state))
  end

  # ── chat: conversations with the autopoet ─────────────────────────────────

  get "/chat/sessions.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.Chat.sessions()))
  end

  get "/chat/transcript" do
    conn = fetch_query_params(conn)

    case Autopoet.Chat.transcript(conn.query_params["id"] || "") do
      {:ok, body} -> text(conn, body)
      _ -> send_resp(conn, 404, "no such chat\n")
    end
  end

  post "/chat/new" do
    authed!(conn, fn conn -> text(conn, Autopoet.Chat.new() <> "\n") end)
  end

  post "/chat/send" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 100_000)

      case Autopoet.Chat.send(conn.query_params["id"], body) do
        {:ok, reply} -> text(conn, reply)
        {:error, reason} -> send_resp(conn, 502, "chat failed: #{inspect(reason)}\n")
      end
    end)
  end

  # ── voice (v1: local TTS via macOS `say`; dictation = Moonshine, fully local) ──

  # notes dictation: audio blob in, plain transcript out (audio deleted after)
  post "/voice/dictate" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 25_000_000)

      ext =
        case get_req_header(conn, "content-type") do
          ["audio/wav" <> _ | _] -> "wav"
          ["audio/aiff" <> _ | _] -> "aiff"
          _ -> "m4a"
        end

      case Autopoet.Dictate.transcribe(body, ext) do
        {:ok, transcript} -> text(conn, transcript)
        {:error, reason} -> send_resp(conn, 422, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # live partial transcription: moonshine-only, called every ~700ms mid-utterance
  post "/voice/dictate/live" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000_000)

      case Autopoet.Dictate.partial(body) do
        {:ok, transcript} -> text(conn, transcript)
        {:error, _} -> send_resp(conn, 204, "")
      end
    end)
  end

  post "/speak" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000)
      Autopoet.Voice.speak(body)
      text(conn, "speaking\n")
    end)
  end

  post "/speak/stop" do
    authed!(conn, fn conn ->
      Autopoet.Voice.stop()
      text(conn, "quiet\n")
    end)
  end

  get "/voice/status" do
    text(conn, to_string(Autopoet.Voice.status()) <> "\n")
  end

  get "/voice/sync.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.Voice.sync()))
  end

  # ── the session deck: a plain-markdown slide file the agent authors as it
  #    talks. Slides separated by "\n---\n". Plain text everywhere. ──
  @deck_dir Path.join([File.cwd!(), "data", "decks"])
  @deck_file Path.join([File.cwd!(), "data", "decks", "current.md"])

  post "/voice/deck/new" do
    authed!(conn, fn conn ->
      File.mkdir_p!(@deck_dir)

      case File.stat(@deck_file) do
        {:ok, %{mtime: mt}} ->
          stamp = mt |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601() |> String.replace(":", "-")
          File.rename(@deck_file, Path.join(@deck_dir, "deck-#{stamp}.md"))

        _ -> :ok
      end

      text(conn, "ok\n")
    end)
  end

  post "/voice/deck/add" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 100_000)
      slide = String.trim(body)
      File.mkdir_p!(@deck_dir)

      deck =
        case File.read(@deck_file) do
          {:ok, prior} when prior != "" -> prior <> "\n---\n" <> slide
          _ -> slide
        end

      File.write!(@deck_file, deck)
      text(conn, deck)
    end)
  end

  get "/voice/deck" do
    text(conn, (File.read(@deck_file) |> elem(1) |> to_string()) <> "")
  end

  # a self-contained-ish export (references the app's vendored reveal assets)
  get "/voice/deck/export" do
    md = case File.read(@deck_file) do
      {:ok, m} -> m
      _ -> ""
    end

    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>autopoet deck</title>
    <link rel="stylesheet" href="/static/vendor/reveal.css">
    <style>body{background:#fafaf7}.reveal{font-family:ui-monospace,Menlo,monospace}</style>
    </head><body><div class="reveal"><div class="slides">
    <section data-markdown data-separator="^\n---\n$"><textarea data-template>#{md}</textarea></section>
    </div></div>
    <script src="/static/vendor/reveal.js"></script>
    <script src="/static/vendor/reveal-markdown.js"></script>
    <script>Reveal.initialize({ plugins: [RevealMarkdown], hash: true });</script>
    </body></html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # streaming brain: raw SSE proxied from the provider — the widget starts
  # synthesizing speech from the first clause while the model is still writing
  post "/voice/brain/stream" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 500_000)

      with {:ok, %{"history" => history}} when is_list(history) <- Jason.decode(body),
           {:ok, ref} <- Autopoet.VoiceBrain.stream_req(history) do
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        brain_stream_loop(conn, ref)
      else
        {:error, :not_configured} -> send_resp(conn, 503, "brain offline\n")
        _ -> send_resp(conn, 400, "bad request\n")
      end
    end)
  end

  # BEAM-native emotion read (GoEmotions RoBERTa): plain text in, "label score" lines out
  post "/voice/affect" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000)

      case Autopoet.Affect.classify(body) do
        {:ok, top} ->
          text(conn, Enum.map_join(top, "\n", fn {l, s} -> "#{l} #{s}" end))

        {:error, _} ->
          send_resp(conn, 204, "")
      end
    end)
  end

  # BEAM-native Kokoro: the widget's primary voice. Plain text in, WAV out.
  get "/voice/tts/status" do
    text(conn, Autopoet.Kokoro.status() <> "\n")
  end

  # TWO local engines behind one route. Kokoro (82M, instant) is the default;
  # Qwen3-TTS 1.7B-4bit/MLX (premium: instruction-directed delivery, 10 langs,
  # 1.83x RT) serves when engine=qwen OR when it's ready and engine is unset
  # (auto-upgrade — never boots implicitly; POST /voice/tts/qwen/boot first).
  post "/voice/tts" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000)
      conn = fetch_query_params(conn)
      q = conn.query_params
      engine = q["engine"]
      use_qwen = engine in ["qwen", "qwen-design", "qwen-clone"] or (engine == nil and Autopoet.QwenTts.ready?())
      # kokoro voice ids (af_heart…) don't name a qwen speaker — map to the default
      qvoice =
        case q["voice"] do
          v when is_binary(v) -> if String.match?(v, ~r/^[a-z]+_/), do: "Ryan", else: v
          _ -> "Ryan"
        end

      result =
        cond do
          engine == "qwen-clone" ->
            # a PINNED voice: data/voices/<name>.wav + .txt (the clip is the identity)
            if Autopoet.QwenTts.model() != :base do
              Autopoet.QwenTts.switch(:base)
              {:error, :base_model_loading}
            else
              vdir = Path.join([Autopoet.Discovery.home(), "data", "voices"])
              name = Path.basename(q["voice"] || "")
              ref = Path.join(vdir, name <> ".wav")
              reftxt = Path.join(vdir, name <> ".txt")

              if File.exists?(ref) and File.exists?(reftxt),
                do: Autopoet.QwenTts.clone(body, ref, String.trim(File.read!(reftxt))),
                else: {:error, :no_such_pinned_voice}
            end

          engine == "qwen-design" and Autopoet.QwenTts.model() != :design ->
            # design personas need the DESIGN model — never cross-speak on
            # custom (delivery-instruction ≠ designed timbre) and never mask
            # with kokoro. Trigger the switch; the client's next clip lands.
            Autopoet.QwenTts.switch(:design)
            {:error, :design_model_loading}

          use_qwen ->
          # qwen-design: the voice IS a description (rides instruct; no presets)
          {qv, qi} =
            if engine == "qwen-design" do
              desc =
                q["design"] || q["instruct"] ||
                  Autopoet.VoicePersonas.description(q["persona"] || Autopoet.VoicePersonas.default())

              {nil, desc}
            else
              {qvoice, q["instruct"]}
            end

          case Autopoet.QwenTts.speak(body, qv, qi) do
            {:ok, wav} -> {:ok, wav}
            # AUTO mode only: the instant engine covers a mid-flight failure.
            # An EXPLICIT qwen/qwen-design request fails loudly — a silent
            # kokoro swap masked the design-model stomp for a full session.
            _ when engine == nil -> Autopoet.Kokoro.speak(body, "af_heart")
            err -> err
          end

          true ->
            Autopoet.Kokoro.speak(body, q["voice"] || "af_heart")
        end

      case result do
        {:ok, wav} ->
          conn |> put_resp_content_type("audio/wav") |> send_resp(200, wav)

        {:error, :not_ready} ->
          send_resp(conn, 503, "voice engine loading\n")

        {:error, reason} ->
          send_resp(conn, 422, "speak failed: #{inspect(reason)}\n")
      end
    end)
  end

  # ── the voice roster: persistent verdicts + takes, served BY the app ──────
  get "/voices/roster" do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Autopoet.VoiceRoster.html(Autopoet.Discovery.token()))
  end

  get "/voices/take/:name" do
    path = Path.join(Autopoet.VoiceRoster.takes_dir(), Path.basename(name))

    if File.exists?(path) and String.ends_with?(name, ".wav") do
      conn |> put_resp_content_type("audio/wav") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no take\n")
    end
  end

  # create a user persona (the roster modal): body = the voice description
  post "/voices/create" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)
      {:ok, body, conn} = read_body(conn, length: 2_000)

      case Autopoet.VoicePersonas.add(conn.query_params["name"] || "", body) do
        {:ok, name} ->
          a = conn.query_params["accent"]
          if a && a != "", do: Autopoet.VoiceRoster.set_accent(name, a)
          text(conn, name <> "\n")

        {:error, _} ->
          send_resp(conn, 422, "name must be 2-24 chars of a-z 0-9 dash; description required\n")
      end
    end)
  end

  # (re)generate a persona's roster take on the design engine. 503 while the
  # model loads — the client retries until 200.
  post "/voices/regen" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)
      name = Path.basename(conn.query_params["name"] || "")
      desc = Autopoet.VoicePersonas.description(name)

      cond do
        desc == nil ->
          send_resp(conn, 404, "no such persona\n")

        Autopoet.QwenTts.model() != :design or not Autopoet.QwenTts.ready?() ->
          Autopoet.QwenTts.switch(:design)
          send_resp(conn, 503, "design engine loading\n")

        true ->
          line =
            "every morning i wake up as an autopoet — a small machine that turns plain words " <>
              "into living systems. that is the strange joy of this work: you speak, i weave, " <>
              "and something real appears."

          case Autopoet.QwenTts.speak(line, nil, desc) do
            {:ok, wav} ->
              File.mkdir_p!(Autopoet.VoiceRoster.takes_dir())
              File.write!(Path.join(Autopoet.VoiceRoster.takes_dir(), name <> ".wav"), wav)
              text(conn, "ok\n")

            {:error, reason} ->
              send_resp(conn, 422, "generation failed: #{inspect(reason)}\n")
          end
      end
    end)
  end

  post "/voices/accent" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)

      case Autopoet.VoiceRoster.set_accent(conn.query_params["name"] || "", conn.query_params["accent"] || "") do
        :ok -> text(conn, "ok\n")
        _ -> send_resp(conn, 422, "bad accent\n")
      end
    end)
  end

  post "/voices/verdict" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)

      case Autopoet.VoiceRoster.set(conn.query_params["name"] || "", conn.query_params["state"] || "") do
        :ok -> text(conn, "ok\n")
      end
    end)
  end

  # boot the premium engine (heavy: ~30s load, ~5.4GB resident) — explicit, never implicit
  post "/voice/tts/qwen/boot" do
    authed!(conn, fn conn ->
      conn = fetch_query_params(conn)
      case conn.query_params["model"] do
        "design" -> Autopoet.QwenTts.switch(:design)
        "custom" -> Autopoet.QwenTts.switch(:custom)
        "base" -> Autopoet.QwenTts.switch(:base)
        _ -> Autopoet.QwenTts.ensure(:custom)
      end
      text(conn, Autopoet.QwenTts.status() <> "\n")
    end)
  end

  get "/voice/tts/qwen/status" do
    text(conn, Autopoet.QwenTts.status() <> "\n")
  end

  # ── the session deck: a plain-markdown slide file the agent authors as it
  #    talks. Slides separated by "\n---\n". Plain text everywhere. ──
  @deck_dir Path.join([File.cwd!(), "data", "decks"])
  @deck_file Path.join([File.cwd!(), "data", "decks", "current.md"])

  post "/voice/deck/new" do
    authed!(conn, fn conn ->
      File.mkdir_p!(@deck_dir)

      case File.stat(@deck_file) do
        {:ok, %{mtime: mt}} ->
          stamp = mt |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601() |> String.replace(":", "-")
          File.rename(@deck_file, Path.join(@deck_dir, "deck-#{stamp}.md"))

        _ -> :ok
      end

      text(conn, "ok\n")
    end)
  end

  post "/voice/deck/add" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 100_000)
      slide = String.trim(body)
      File.mkdir_p!(@deck_dir)

      deck =
        case File.read(@deck_file) do
          {:ok, prior} when prior != "" -> prior <> "\n---\n" <> slide
          _ -> slide
        end

      File.write!(@deck_file, deck)
      text(conn, deck)
    end)
  end

  get "/voice/deck" do
    text(conn, (File.read(@deck_file) |> elem(1) |> to_string()) <> "")
  end

  # a self-contained-ish export (references the app's vendored reveal assets)
  get "/voice/deck/export" do
    md = case File.read(@deck_file) do
      {:ok, m} -> m
      _ -> ""
    end

    html = """
    <!doctype html><html><head><meta charset="utf-8"><title>autopoet deck</title>
    <link rel="stylesheet" href="/static/vendor/reveal.css">
    <style>body{background:#fafaf7}.reveal{font-family:ui-monospace,Menlo,monospace}</style>
    </head><body><div class="reveal"><div class="slides">
    <section data-markdown data-separator="^\n---\n$"><textarea data-template>#{md}</textarea></section>
    </div></div>
    <script src="/static/vendor/reveal.js"></script>
    <script src="/static/vendor/reveal-markdown.js"></script>
    <script>Reveal.initialize({ plugins: [RevealMarkdown], hash: true });</script>
    </body></html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # streaming brain: raw SSE proxied from the provider — the widget starts
  # synthesizing speech from the first clause while the model is still writing
  post "/voice/brain/stream" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 500_000)

      with {:ok, %{"history" => history}} when is_list(history) <- Jason.decode(body),
           {:ok, ref} <- Autopoet.VoiceBrain.stream_req(history) do
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        brain_stream_loop(conn, ref)
      else
        {:error, :not_configured} -> send_resp(conn, 503, "brain offline\n")
        _ -> send_resp(conn, 400, "bad request\n")
      end
    end)
  end

  # BEAM-native emotion read (GoEmotions RoBERTa): plain text in, "label score" lines out
  post "/voice/affect" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000)

      case Autopoet.Affect.classify(body) do
        {:ok, top} ->
          text(conn, Enum.map_join(top, "\n", fn {l, s} -> "#{l} #{s}" end))

        {:error, _} ->
          send_resp(conn, 204, "")
      end
    end)
  end

  # ── the voice lab: tune each mood's style tag + sampler dials, hear it,
  #    save. Presets persist as plain text (data/voice-moods.txt) and drive
  #    the live avatar's per-mood delivery. ──
  get "/voice/lab" do
    html =
      [:code.priv_dir(:autopoet), "static", "voicelab.html"]
      |> Path.join()
      |> File.read!()
      |> String.replace("__TOKEN__", Autopoet.Discovery.token())

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, html)
  end

  @moods_file Path.join([File.cwd!(), "data", "voice-moods.txt"])

  get "/voice/moods" do
    text(conn, (File.read(@moods_file) |> elem(1) |> to_string()) <> "")
  end

  post "/voice/moods/save" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 20_000)
      File.write!(@moods_file, String.trim(body) <> "\n")
      text(conn, "ok\n")
    end)
  end

  # BEAM-native Kokoro: the widget's primary voice. Plain text in, WAV out.
  get "/voice/tts/status" do
    text(conn, Autopoet.Kokoro.status() <> "\n")
  end

  post "/voice/tts" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 4_000)
      voice = conn.query_params["voice"] || "af_heart"

      engine =
        conn.query_params["engine"] || System.get_env("AUTOPOET_TTS") ||
          if(Autopoet.Chatterbox.ready?(), do: "chatterbox", else: "kokoro")

      result =
        case engine do
          "chatterbox" ->
            # sampler knobs pass straight through: ?temp=&top_p=&top_k=&rep=&min_p=
            knobs =
              %{
                "t" => conn.query_params["temp"],
                "p" => conn.query_params["top_p"],
                "k" => conn.query_params["top_k"],
                "r" => conn.query_params["rep"],
                "m" => conn.query_params["min_p"],
                "s" => conn.query_params["seed"]
              }
              |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
              |> Map.new()

            case Autopoet.Chatterbox.speak(body, knobs) do
              {:ok, _} = ok -> ok
              # quality engine down → the fast engine still answers
              {:error, _} -> Autopoet.Kokoro.speak(body, voice)
            end

          _ ->
            Autopoet.Kokoro.speak(body, voice)
        end

      case result do
        {:ok, wav} ->
          conn |> put_resp_content_type("audio/wav") |> send_resp(200, wav)

        {:error, :not_ready} ->
          send_resp(conn, 503, "voice engine loading\n")

        {:error, reason} ->
          send_resp(conn, 422, "speak failed: #{inspect(reason)}\n")
      end
    end)
  end

  # stage | live | local — the UI picks its voice pipeline by this.
  # "stage" = the local speech-to-speech whiteboard (Silero VAD → local STT →
  # Groq brain → Kokoro), preferred whenever the Groq key is configured.
  get "/voice/mode" do
    mode =
      cond do
        Autopoet.VoiceBrain.available?() -> "stage"
        Autopoet.GeminiLive.available?() -> "live"
        true -> "local"
      end

    text(conn, mode <> "\n")
  end

  # ── the local speech-to-speech widget (VAD → Moonshine/Whisper → Groq → Kokoro) ──

  get "/voice/widget" do
    html =
      [:code.priv_dir(:autopoet), "static", "voice.html"]
      |> Path.join()
      |> File.read!()
      |> String.replace("__TOKEN__", Autopoet.Discovery.token())

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, html)
  end

  # vendored voice runtime pieces (onnx models, worklets, esm bundles)
  # the split app: app.html is a thin shell; JS/CSS live in small files under
  # static/js + static/css (the god-file is dead — keep files ≤~200 lines)
  get "/static/js/:name" do
    path = Path.join([:code.priv_dir(:autopoet), "static", "js", Path.basename(name)])

    if File.exists?(path) and String.ends_with?(name, ".js") do
      conn |> put_resp_content_type("application/javascript") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no such script\n")
    end
  end

  get "/static/css/:name" do
    path = Path.join([:code.priv_dir(:autopoet), "static", "css", Path.basename(name)])

    if File.exists?(path) and String.ends_with?(name, ".css") do
      conn |> put_resp_content_type("text/css") |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no such stylesheet\n")
    end
  end

  get "/static/vendor/:name" do
    safe = Path.basename(name)
    path = Path.join([:code.priv_dir(:autopoet), "static", "vendor", safe])

    if File.exists?(path) do
      mime =
        case Path.extname(safe) do
          ".js" -> "application/javascript"
          ".mjs" -> "application/javascript"
          ".onnx" -> "application/octet-stream"
          ".wasm" -> "application/wasm"
          _ -> "application/octet-stream"
        end

      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, File.read!(path))
    else
      send_resp(conn, 404, "no such vendor file\n")
    end
  end

  # one conversational turn for the voice widget: history in, cue-script out
  post "/voice/brain" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 200_000)

      with {:ok, %{"history" => history}} when is_list(history) <- Jason.decode(body),
           {:ok, reply} <- Autopoet.VoiceBrain.reply(history) do
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{reply: reply}))
      else
        {:error, :not_configured} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(503, Jason.encode!(%{error: "GROQ_API_KEY not configured"}))

        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(502, Jason.encode!(%{error: "brain failed", detail: inspect(reason) |> String.slice(0, 200)}))

        _ ->
          send_resp(conn, 422, "history required\n")
      end
    end)
  end

  # compile agent-authored D2 into SVG for the widget's diagram stage.
  # Local `d2` binary, fixed args, temp files, 2s cap — the source is model
  # output, never shell-interpolated.
  post "/voice/d2" do
    authed!(conn, fn conn ->
      {:ok, src, conn} = read_body(conn, length: 20_000)
      base = Path.join(System.tmp_dir!(), "apd2-#{System.unique_integer([:positive])}")
      d2file = base <> ".d2"
      svg = base <> ".svg"

      try do
        File.write!(d2file, src)

        case System.cmd("d2", ["--theme=0", "--pad=12", d2file, svg], stderr_to_stdout: true) do
          {_, 0} ->
            conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, File.read!(svg))

          {out, _} ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(422, "d2: " <> String.slice(out, 0, 300))
        end
      rescue
        e in ErlangError ->
          send_resp(conn, 503, "d2 binary not available: #{inspect(e.original)}\n")
      after
        File.rm(d2file)
        File.rm(svg)
      end
    end)
  end

  # the realtime call: browser WebSocket ⇄ Gemini Live (token in query — the
  # WS API can't set headers)
  get "/voice/live" do
    conn = fetch_query_params(conn)

    if conn.query_params["token"] == Autopoet.Discovery.token() do
      conn
      |> WebSockAdapter.upgrade(Autopoet.VoiceSock, %{}, timeout: 600_000)
      |> halt()
    else
      send_resp(conn, 401, "bad token\n")
    end
  end

  post "/notes/save" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 10_000_000)
      Autopoet.Notes.write(conn.query_params["path"], body)
      text(conn, "saved\n")
    end)
  end

  post "/notes/new" do
    authed!(conn, fn conn ->
      q = conn.query_params

      meta = %{
        "type" => q["type"],
        "icon" => q["icon"],
        "tags" => (q["tags"] || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      }

      case Autopoet.Notes.create(q["path"], q["kind"] || "note", meta) do
        :ok -> text(conn, "created\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # update an existing item's metadata (type/icon/tags) — the edit-modal save path
  post "/notes/meta" do
    authed!(conn, fn conn ->
      q = conn.query_params

      Autopoet.Notes.set_meta(q["path"], %{
        "type" => q["type"],
        "icon" => q["icon"],
        "tags" => (q["tags"] || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      })

      text(conn, "meta saved\n")
    end)
  end

  post "/notes/rename" do
    authed!(conn, fn conn ->
      case Autopoet.Notes.rename(conn.query_params["from"], conn.query_params["to"]) do
        :ok -> text(conn, "renamed\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/notes/delete" do
    authed!(conn, fn conn ->
      case Autopoet.Notes.delete(conn.query_params["path"]) do
        :ok -> text(conn, "deleted\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/notes/reorder" do
    authed!(conn, fn conn ->
      names = String.split(conn.query_params["names"] || "", "\n", trim: true)
      Autopoet.Notes.reorder(conn.query_params["dir"] || "", names)
      text(conn, "reordered\n")
    end)
  end

  get "/graph.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Autopoet.WorldGraph.payload()))
  end

  # the previous log-page (kept at /plain for curl-friendly debugging)
  get "/plain" do
    conn |> put_resp_content_type("text/html") |> send_resp(200, page())
  end

  # Lightweight liveness probe for the cloud machine's Fly health check — no subsystem deps, always 200,
  # so a hiccup in a Worker/Watchdog/Shadow stat can't flap the check the way GET /status could. Public.
  # (The provisioner health-checks /status today; switch it to /health on the next autopoet image build.)
  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/status" do
    st = Nexus.Autopoet.Worker.status()
    {up_ms, _} = :erlang.statistics(:wall_clock)
    {soft, hard} = Autopoet.Watchdog.caps()

    hebb = Autopoet.Shadow.Hebb.stats()
    surprise = Autopoet.Shadow.Surprise.stats()

    body = """
    armed: #{st.armed}
    spec: #{inspect(st.spec)}
    next_ms: #{inspect(st.next_ms)}
    last_cycle: #{inspect(st.last)}
    memory_mb: #{div(:erlang.memory(:total), 1_048_576)} (soft #{soft} / hard #{hard})
    uptime_s: #{div(up_ms, 1000)}
    window: #{if Process.whereis(Autopoet.Window), do: "open", else: "headless"}
    captured_events: #{Autopoet.Capture.count()}
    shadow_hebb: #{hebb.events} events, #{hebb.nodes} nodes, #{hebb.edges} edges, top #{inspect(hebb.top)}
    shadow_surprise: #{surprise.events} events, fast #{fmt(surprise.fast)} / slow #{fmt(surprise.slow)} bits, alarms #{surprise.alarms}
    """

    text(conn, body)
  end

  get "/log" do
    text(conn, Enum.join(Log.recent(200), "\n") <> "\n")
  end

  get "/avatar" do
    conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, Autopoet.Avatar.svg())
  end

  get "/avatar/mouths.json" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Autopoet.Avatar.mouths()))
  end

  get "/proposals" do
    body =
      case Autopoet.Proposals.list() do
        [] -> "no proposals\n"
        ps -> Enum.map_join(ps, "\n", fn {id, status} -> "#{id} #{status}" end) <> "\n"
      end

    text(conn, body)
  end

  # Proposals now suggest edits to the VAULT (the human's notes / source of truth) —
  # the ONE thing the agent can't write directly. Accepting applies to data/notes and
  # re-fires translation, exactly as if the human had made the edit. (The body — .work —
  # the agent writes directly via Autopoet.Body; no proposal.)
  post "/proposal/:id/accept" do
    authed!(conn, fn conn ->
      case Autopoet.Proposals.accept(id, Autopoet.Notes.dir()) do
        :ok ->
          # a vault change the human accepted → let it translate like any note edit
          for {rel, _} <- Autopoet.Proposals.changes(id) do
            with {:ok, content} <- File.read(Path.join(Autopoet.Notes.dir(), rel)),
                 do: Autopoet.Notes.write(rel, content)
          end

          text(conn, "accepted #{id}\n")

        {:error, reason} ->
          text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/proposal/:id/reject" do
    authed!(conn, fn conn ->
      case Autopoet.Proposals.reject(id, conn.query_params["reason"]) do
        :ok -> text(conn, "rejected #{id}\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/proposal/:id/revert" do
    authed!(conn, fn conn ->
      case Autopoet.Proposals.revert(id, Autopoet.Notes.dir()) do
        :ok -> text(conn, "reverted #{id}\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  # ── the project spine (lifecycle-plan §1): full CLI control ─────────────────

  get "/projects" do
    body =
      case Autopoet.Projects.list() do
        [] ->
          "no projects\n"

        ps ->
          Enum.map_join(ps, "\n", fn {slug, p} ->
            "#{slug} #{p.status} archetype=#{p.archetype} chartered=#{p.chartered} desk=#{if p.desk_running, do: "running", else: "stopped"}"
          end) <> "\n"
      end

    text(conn, body)
  end

  # conversational creation: the request BODY is what you'd say to the agent —
  # it becomes the project's onboarding note; genesis runs from it.
  post "/projects/new" do
    authed!(conn, fn conn ->
      slug = conn.query_params["slug"] || "project-#{System.os_time(:second)}"
      archetype = String.to_atom(conn.query_params["archetype"] || "venture")
      {:ok, prompt, conn} = Plug.Conn.read_body(conn)

      case Autopoet.Projects.create(slug, archetype: archetype) do
        {:ok, p} ->
          if String.trim(prompt) != "" do
            dir = Autopoet.Projects.artifacts_dir(p.slug)
            File.mkdir_p!(dir)
            File.write!(Path.join(dir, "onboarding.txt"), prompt)
          end

          case Autopoet.Desks.launch(p.slug) do
            {:ok, _} -> text(conn, "created #{p.slug} — desk running, genesis begins\n")
            {:error, why} -> text(conn, "created #{p.slug} — desk failed: #{inspect(why)}\n")
          end

        {:error, :exists} ->
          text(conn, "refused: project exists\n")
      end
    end)
  end

  get "/projects/:slug/status" do
    case Autopoet.Projects.get(slug) do
      nil ->
        text(conn, "unknown project\n")

      p ->
        hb = Path.join(Autopoet.Projects.artifacts_dir(slug), "state.txt")
        state = case File.read(hb) do
          {:ok, t} -> t
          _ -> "(no heartbeat yet)\n"
        end

        text(conn, "#{slug} #{p.status} chartered=#{p.chartered} desk=#{p.desk_running}\n#{state}")
    end
  end

  post "/projects/:slug/desk/start" do
    authed!(conn, fn conn ->
      case Autopoet.Desks.launch(slug) do
        {:ok, _} -> text(conn, "desk running: #{slug}\n")
        {:error, why} -> text(conn, "refused: #{inspect(why)}\n")
      end
    end)
  end

  post "/projects/:slug/desk/stop" do
    authed!(conn, fn conn ->
      Autopoet.Desks.halt(slug)
      text(conn, "desk stopped: #{slug}\n")
    end)
  end

  post "/projects/:slug/archive" do
    authed!(conn, fn conn ->
      case Autopoet.Projects.archive(slug) do
        :ok -> text(conn, "archived #{slug}\n")
        {:error, why} -> text(conn, "refused: #{inspect(why)}\n")
      end
    end)
  end

  # the BATCHED DIGEST (locked decision #4): pending proposals grouped by
  # project — reviewed when the operator opens the app / runs ctl, never pinged.
  get "/digest" do
    pending = Autopoet.Proposals.pending()

    grouped =
      Enum.group_by(pending, fn {id, _} ->
        case Autopoet.Proposals.target_of(id) do
          "projects/" <> rest -> rest |> String.split("/") |> hd()
          _ -> "(organism)"
        end
      end)

    body =
      if grouped == %{} do
        "digest empty — nothing pending\n"
      else
        Enum.map_join(grouped, "\n", fn {proj, items} ->
          "## #{proj}\n" <>
            Enum.map_join(items, "\n", fn {id, _} -> "  #{id} → #{Autopoet.Proposals.target_of(id)}" end)
        end) <> "\n"
      end

    text(conn, body)
  end

  get "/sse" do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    conn =
      Enum.reduce_while(Log.recent(50), conn, fn line, c ->
        case chunk(c, "data: #{line}\n\n") do
          {:ok, c} -> {:cont, c}
          {:error, _} -> {:halt, c}
        end
      end)

    Log.subscribe()
    sse_loop(conn)
  end

  post "/arm" do
    authed!(conn, fn conn ->
      every = conn.query_params["every"] || "15m"
      Nexus.Autopoet.Worker.arm(every)
      Log.puts("heartbeat ARMED (every #{every}) via ctl")
      text(conn, "armed every #{every}\n")
    end)
  end

  post "/disarm" do
    authed!(conn, fn conn ->
      Nexus.Autopoet.Worker.disarm()
      Log.puts("heartbeat DISARMED via ctl")
      text(conn, "disarmed\n")
    end)
  end

  post "/close" do
    authed!(conn, fn conn ->
      case Process.whereis(Autopoet.Window) do
        nil ->
          text(conn, "no window (headless)\n")

        _pid ->
          Log.puts("close requested via ctl — driving the window's kill switch")
          Autopoet.Window.close()
          text(conn, "closing — BEAM will halt\n")
      end
    end)
  end

  # Cosmetic, page-driven (no token): match the native chrome to the page theme.
  # Local-only server; the page POSTs this whenever the light/dark toggle flips.
  post "/chrome-theme" do
    theme = if conn.query_params["t"] == "dark", do: :dark, else: :light

    case Process.whereis(Autopoet.Window) do
      nil -> text(conn, "no window (headless)\n")
      _pid -> Autopoet.Window.set_theme(theme); text(conn, "ok\n")
    end
  end

  post "/request" do
    authed!(conn, fn conn ->
      target = conn.query_params["target"]
      change = conn.query_params["change"]

      case Autopoet.Requests.file(target, change) do
        :ok -> text(conn, "filed: #{target} — #{change}\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
    end)
  end

  post "/cycle" do
    authed!(conn, fn conn ->
      report = Autopoet.Brain.cycle()
      text(conn, "cycle: sensed #{report.sensed}, results #{inspect(Enum.map(report.results, & &1.action))}\n")
    end)
  end

  post "/limb" do
    authed!(conn, fn conn ->
      name = conn.query_params["name"] || ""
      task = conn.query_params["task"] || ""

      if name == "" or task == "" do
        text(conn, "usage: limb?name=<limb>&task=<task>\n")
      else
        {:ok, out} = Autopoet.Limbs.dispatch(name, task)
        text(conn, "dispatched #{name} (async) -> #{out}\n")
      end
    end)
  end

  post "/research" do
    authed!(conn, fn conn ->
      q = conn.query_params["q"] || ""

      if q == "" do
        text(conn, "usage: research?q=<question>\n")
      else
        Autopoet.Limbs.research(q)
        text(conn, "limb dispatched (async) — watch the log; findings arrive as a request, then a proposal\n")
      end
    end)
  end

  # NOTE: the /oota host verb is gone — canon forbids native processes. OOTA is now a
  # reference LIBRARY seeded into the world at /work/oota (Autopoet.Oota.seed_reference/0);
  # agents read recipes there and re-express them in the wasm-native lanes.

  post "/win/:action" do
    authed!(conn, fn conn ->
      Autopoet.Window.control(String.to_existing_atom(action))
      text(conn, "ok\n")
    end)
  end

  post "/kill" do
    authed!(conn, fn conn ->
      Log.puts("KILL via ctl — halting BEAM")
      spawn(fn ->
        Process.sleep(150)
        :init.stop()
      end)

      text(conn, "halting\n")
    end)
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  # the cloud host is ready only when Nexus.Cloud's Fly broker is configured with a
  # DEDICATED org (the fail-safe) — dark otherwise, so the card can't imply hosting
  defp cloud_host_ready? do
    Code.ensure_loaded?(Nexus.Cloud.Fly) and Nexus.Cloud.Fly.configured?()
  rescue
    _ -> false
  end

  defp text(conn, body), do: conn |> put_resp_content_type("text/plain") |> send_resp(200, body)

  defp fmt(nil), do: "-"
  defp fmt(x), do: Float.round(x * 1.0, 2)

  # forward provider SSE bytes to the widget as they arrive
  defp brain_stream_loop(conn, ref) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        brain_stream_loop(conn, ref)

      {:http, {^ref, :stream, chunk}} ->
        case chunk(conn, chunk) do
          {:ok, conn} -> brain_stream_loop(conn, ref)
          {:error, _} ->
            :httpc.cancel_request(ref)
            conn
        end

      {:http, {^ref, :stream_end, _headers}} ->
        conn

      {:http, {^ref, {:error, _reason}}} ->
        conn
    after
      60_000 ->
        :httpc.cancel_request(ref)
        conn
    end
  end

  defp authed!(conn, fun) do
    conn = fetch_query_params(conn)

    if get_req_header(conn, "authorization") == ["Bearer " <> Autopoet.Discovery.token()] do
      fun.(conn)
    else
      conn |> put_resp_content_type("text/plain") |> send_resp(401, "bad token\n")
    end
  end

  defp sse_loop(conn) do
    receive do
      {:autopoet_log, line} ->
        case chunk(conn, "data: #{line}\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    after
      15_000 ->
        case chunk(conn, ": ping\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp page do
    """
    <!doctype html>
    <meta charset="utf-8">
    <title>autopoet</title>
    <style>
      body { background:#fff; color:#222; font:12px/1.5 ui-monospace,monospace;
             max-width:72rem; margin:2rem auto; padding:0 1rem; }
      pre { white-space:pre-wrap; word-break:break-all; }
      .card { border:1px solid #ddd; border-radius:6px; padding:1rem; margin:1rem 0; }
      .card h3 { margin:0 0 .5rem 0; font-size:13px; }
      .chg { background:#fafafa; border:1px solid #eee; padding:.5rem; }
      button { font:inherit; padding:.2rem .8rem; cursor:pointer; }
      .ok { background:#e8f5e9; } .no { background:#fdecea; }
    </style>
    <div style="text-align:center;margin-bottom:1rem"><img src="/avatar" width="240" alt=""></div>
    #{proposals_html()}
    <pre id="log"></pre>
    <script>
      const TOKEN = "#{Autopoet.Discovery.token()}";
      function act(id, verb) {
        fetch(`/proposal/${id}/${verb}`, {method:"POST", headers:{authorization:`Bearer ${TOKEN}`}})
          .then(() => location.reload());
      }
      const log = document.getElementById("log");
      new EventSource("/sse").onmessage = (e) => {
        log.textContent += e.data + "\\n";
        window.scrollTo(0, document.body.scrollHeight);
      };
    </script>
    """
  end

  # The review surface: every pending proposal, full file contents, accept/reject.
  # Localhost-only server; the per-boot token is embedded so the buttons are the
  # same authenticated verbs the CLI uses.
  defp proposals_html do
    case Autopoet.Proposals.list() |> Enum.filter(fn {_, s} -> s == "pending" end) do
      [] ->
        ""

      pending ->
        cards =
          Enum.map_join(pending, "\n", fn {id, _} ->
            item = [Autopoet.Proposals.dir(), id, "item.txt"] |> Path.join() |> File.read!() |> esc()

            files =
              Enum.map_join(Autopoet.Proposals.changes(id), "", fn {rel, src} ->
                "<h4>#{esc(rel)}</h4><pre class=\"chg\">#{esc(src)}</pre>"
              end) <>
                Enum.map_join(Autopoet.Proposals.appends(id), "", fn {rel, src} ->
                  "<h4>append → #{esc(rel)}</h4><pre class=\"chg\">#{esc(src)}</pre>"
                end)

            """
            <div class="card">
              <h3>#{id}
                <button class="ok" onclick="act('#{id}','accept')">Accept</button>
                <button class="no" onclick="act('#{id}','reject')">Reject</button>
              </h3>
              <details><summary>sensed item</summary><pre>#{item}</pre></details>
              #{files}
            </div>
            """
          end)

        "<h2>pending proposals</h2>" <> cards
    end
  end

  defp esc(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
