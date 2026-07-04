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

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
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

  # ── Workbooks Cloud sign-in (browser device flow) ────────────────────────────────────────────────
  # Open the cloud login with our localhost callback; after you authenticate the cloud mints a `wbk_`
  # PAT and redirects to /auth/cloud/callback. Same shape as the OAuth cards: open → poll status.
  post "/auth/cloud/open" do
    cb = "http://127.0.0.1:#{conn.port}/auth/cloud/callback"
    url = Autopoet.Cloud.base_url() <> "/login/?device=autopoet&cb=" <> URI.encode_www_form(cb)
    spawn(fn -> System.cmd("open", [url]) end)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  # The cloud redirects here with the minted PAT; store it and confirm in the tab (which pings the opener).
  get "/auth/cloud/callback" do
    conn = fetch_query_params(conn)

    case Autopoet.Cloud.put_token(conn.query_params["token"] || "") do
      :ok ->
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

  post "/auth/cloud/disconnect" do
    authed!(conn, fn conn ->
      Autopoet.Cloud.disconnect()
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true}))
    end)
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

  # live | local — the UI picks its voice pipeline by this
  get "/voice/mode" do
    text(conn, if(Autopoet.GeminiLive.available?(), do: "live\n", else: "local\n"))
  end

  # ── the local speech-to-speech widget (VAD → Moonshine/Whisper → Groq → Kokoro) ──

  get "/voice/widget" do
    html =
      [:code.priv_dir(:autopoet), "static", "voice.html"]
      |> Path.join()
      |> File.read!()
      |> String.replace("__TOKEN__", Autopoet.Discovery.token())

    conn |> put_resp_content_type("text/html") |> send_resp(200, html)
  end

  # vendored voice runtime pieces (onnx models, worklets, esm bundles)
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

      conn |> put_resp_content_type(mime) |> send_resp(200, File.read!(path))
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
