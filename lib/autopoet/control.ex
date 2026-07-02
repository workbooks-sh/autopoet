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

  post "/notes/save" do
    authed!(conn, fn conn ->
      {:ok, body, conn} = read_body(conn, length: 10_000_000)
      Autopoet.Notes.write(conn.query_params["path"], body)
      text(conn, "saved\n")
    end)
  end

  post "/notes/new" do
    authed!(conn, fn conn ->
      case Autopoet.Notes.create(conn.query_params["path"], conn.query_params["kind"] || "note") do
        :ok -> text(conn, "created\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
      end
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

  post "/proposal/:id/accept" do
    authed!(conn, fn conn ->
      case Autopoet.Proposals.accept(id, Nexus.Paths.data_dir()) do
        :ok -> text(conn, "accepted #{id}\n")
        {:error, reason} -> text(conn, "refused: #{inspect(reason)}\n")
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
      case Autopoet.Proposals.revert(id, Nexus.Paths.data_dir()) do
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

  post "/oota" do
    authed!(conn, fn conn ->
      args = String.split(conn.query_params["args"] || "", " ", trim: true)

      case Autopoet.Oota.run(args) do
        {:ok, out} -> text(conn, out)
        {:error, reason} -> text(conn, "oota error: #{inspect(reason)}\n")
      end
    end)
  end

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
