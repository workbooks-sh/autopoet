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
      case Autopoet.Proposals.reject(id) do
        :ok -> text(conn, "rejected #{id}\n")
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
    </style>
    <div style="text-align:center;margin-bottom:1rem"><img src="/avatar" width="240" alt=""></div>
    <pre id="log"></pre>
    <script>
      const log = document.getElementById("log");
      new EventSource("/sse").onmessage = (e) => {
        log.textContent += e.data + "\\n";
        window.scrollTo(0, document.body.scrollHeight);
      };
    </script>
    """
  end
end
