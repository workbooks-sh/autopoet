defmodule Autopoet.Composio do
  @moduledoc """
  The agent's toolbelt — Composio's 1000+ app library, driven straight from
  Elixir over REST (there's no Elixir SDK). This is the LOCAL, single-user
  capability: the desktop autopoet connects its own Gmail/Slack/Notion/etc. and
  can call those tools. The multi-tenant, whitelabeled version lives in the
  Workbooks Cloud control plane; this is the buildable-now half.

  Auth: `COMPOSIO_API_KEY` via `Nexus.Secrets` (env). No key → every call returns
  `{:skip, :no_key}`, so the feature is dark until the key lands (same pattern as
  `Nexus.Google`). The local user is a single stable id (`@user`).

  Key surfaces (v3 REST, base `backend.composio.dev`):
    * `toolkits/0`         — the app catalog (Gmail, Slack, …)
    * `tools/1`            — the tools of a toolkit (as LLM function schemas)
    * `connect/1`          — start connecting a toolkit → a redirect_url the user
                             completes; the grant lands as a connected account
    * `connection/1`       — poll a connection until ACTIVE
    * `connections/0`      — the user's connected accounts
    * `mcp_url/1`          — a per-user MCP endpoint exposing the connected tools,
                             for the agent's MCP client (the clean execution path)
    * `execute/2`          — run one tool directly (the REST alternative to MCP)
  """

  @base "https://backend.composio.dev/api"
  @user "autopoet-local"

  @doc "Is Composio available (an API key is present)?"
  def configured?, do: is_binary(key())

  @doc "The app catalog. opts: `limit`, `category`."
  def toolkits(opts \\ []) do
    q = URI.encode_query(Keyword.take(opts, [:limit, :category]))
    get("/v3/toolkits" <> if(q == "", do: "", else: "?" <> q))
  end

  @doc "Tools of a toolkit, as LLM function-calling schemas."
  def tools(toolkit) when is_binary(toolkit) do
    get("/v3.1/tools?" <> URI.encode_query(%{"toolkit_slugs" => toolkit}))
  end

  @doc """
  Start connecting a toolkit for the local user. Returns
  `{:ok, %{redirect_url: url, id: id}}` — open `redirect_url` in the browser; the
  grant becomes a connected account. `auth_config_id` (an `ac_…`) may be passed
  to use a whitelabeled custom auth config; omitted, Composio's managed auth is
  used (its brand on the consent screen — fine locally, replace for production).
  """
  def connect(toolkit, opts \\ []) when is_binary(toolkit) do
    body = %{
      "toolkit" => %{"slug" => toolkit},
      "connection" => %{"user_id" => @user, "state" => %{"authScheme" => "OAUTH2"}}
    }

    body =
      case opts[:auth_config_id] do
        ac when is_binary(ac) -> put_in(body, ["auth_config"], %{"id" => ac})
        _ -> body
      end

    body =
      case opts[:callback_url] do
        cb when is_binary(cb) -> put_in(body, ["connection", "callback_url"], cb)
        _ -> body
      end

    case post("/v3.1/connected_accounts", body) do
      {:ok, %{"redirect_url" => url, "id" => id}} -> {:ok, %{redirect_url: url, id: id}}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  @doc "Poll a connection by id → its status (INITIATED | ACTIVE | FAILED | …)."
  def connection(id) when is_binary(id) do
    case get("/v3.1/connected_accounts/#{id}") do
      {:ok, %{"status" => s} = c} -> {:ok, %{status: s, active: s == "ACTIVE", raw: c}}
      err -> err
    end
  end

  @doc "The local user's connected accounts."
  def connections do
    get("/v3.1/connected_accounts?" <> URI.encode_query(%{"user_ids" => @user}))
  end

  @doc """
  A per-user MCP endpoint URL exposing the given toolkits' tools, scoped to the
  local user's connected accounts. The agent's MCP client connects to it with the
  `x-api-key` header. `toolkits` is a list of slugs; `allowed_tools` optional.
  """
  def mcp_url(toolkits, opts \\ []) when is_list(toolkits) do
    body =
      %{"toolkits" => toolkits, "name" => opts[:name] || "autopoet"}
      |> then(fn m -> if opts[:allowed_tools], do: Map.put(m, "allowed_tools", opts[:allowed_tools]), else: m end)

    with {:ok, %{"id" => server_id}} <- post("/v3/mcp/servers", body) do
      {:ok, "#{@base}/../v3/mcp/#{server_id}?user_id=#{@user}", server_id}
    end
  end

  @doc "Execute a tool directly (REST path). `action` is a tool slug."
  def execute(action, arguments) when is_binary(action) and is_map(arguments) do
    post("/v3/tools/execute/#{action}", %{"arguments" => arguments, "user_id" => @user})
  end

  # ── HTTP ─────────────────────────────────────────────────────────────────────
  defp get(path), do: req(:get, path, nil)
  defp post(path, body), do: req(:post, path, body)

  defp req(method, path, body) do
    case key() do
      nil ->
        {:skip, :no_key}

      k ->
        :inets.start()
        :ssl.start()
        url = String.to_charlist(@base <> path)
        headers = [{~c"x-api-key", String.to_charlist(k)}, {~c"accept", ~c"application/json"}]

        request =
          case method do
            :get -> {url, headers}
            :post -> {url, headers, ~c"application/json", String.to_charlist(Jason.encode!(body || %{}))}
          end

        case :httpc.request(method, request, [timeout: 30_000], body_format: :binary) do
          {:ok, {{_, code, _}, _, resp}} when code in 200..299 -> {:ok, Jason.decode!(to_string(resp))}
          {:ok, {{_, code, _}, _, resp}} -> {:error, {:http, code, String.slice(to_string(resp), 0, 300)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp key, do: Nexus.Secrets.get("COMPOSIO_API_KEY")
end
