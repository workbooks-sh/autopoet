defmodule Autopoet.AgentMail do
  @moduledoc """
  AgentMail — first-class email for agents (api.agentmail.to). The venture desk
  owns real inboxes (citeflows@agentmail.to) it can READ programmatically; the
  site's public proxies (beta@citeflows.com via Cloudflare Email Routing)
  forward here, so inbound practitioner replies land where the agent can see
  them and count toward its validation metrics.

  SEND is an OUTWARD action: call sites must route drafts through the proposal
  gate (same as X posts) — this module only provides the transport. Key from
  AGENTMAIL_API_KEY (env/.env); every function returns {:skip, :not_configured}
  without it. Injectable `:transport` for evals.
  """

  @base "https://api.agentmail.to/v0"

  def configured?, do: is_binary(key())

  @doc "Create (or idempotently claim) an inbox. Returns {:ok, %{\"email\" => …}}."
  def create_inbox(username, display_name, opts \\ []) do
    post("/inboxes", %{"username" => username, "display_name" => display_name}, opts)
  end

  @doc "List messages in an inbox (newest first)."
  def messages(inbox, opts \\ []) do
    get("/inboxes/#{URI.encode(inbox)}/messages", opts)
  end

  @doc "Read one message (full body)."
  def message(inbox, message_id, opts \\ []) do
    get("/inboxes/#{URI.encode(inbox)}/messages/#{URI.encode(message_id)}", opts)
  end

  @doc "SEND — OUTWARD: gate at the call site (proposal-approved content only)."
  def send_message(inbox, %{} = m, opts \\ []) do
    body = %{
      "to" => List.wrap(m[:to] || m["to"]),
      "subject" => m[:subject] || m["subject"] || "",
      "text" => m[:text] || m["text"] || ""
    }

    post("/inboxes/#{URI.encode(inbox)}/messages/send", body, opts)
  end

  # ── plumbing ─────────────────────────────────────────────────────────────────

  defp get(path, opts), do: request(:get, path, nil, opts)
  defp post(path, body, opts), do: request(:post, path, body, opts)

  defp request(method, path, body, opts) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 3) ->
        fun.(method, path, body)

      _ ->
        case key() do
          nil -> {:skip, :not_configured}
          k -> live(method, @base <> path, body, k)
        end
    end
  end

  defp live(method, url, body, k) do
    :inets.start()
    :ssl.start()
    h = [{~c"authorization", String.to_charlist("Bearer " <> k)}, {~c"accept", ~c"application/json"}]

    req =
      case method do
        :get -> {String.to_charlist(url), h}
        :post -> {String.to_charlist(url), h, ~c"application/json", String.to_charlist(Jason.encode!(body || %{}))}
      end

    case :httpc.request(method, req, [timeout: 20_000], body_format: :binary) do
      {:ok, {{_, code, _}, _, resp}} when code in 200..299 ->
        case Jason.decode(to_string(resp)) do
          {:ok, m} -> {:ok, m}
          _ -> {:ok, to_string(resp)}
        end

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, {:http, code, String.slice(to_string(resp), 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp key do
    System.get_env("AGENTMAIL_API_KEY") ||
      (try do
         Nexus.Secrets.get("AGENTMAIL_API_KEY")
       rescue
         _ -> nil
       end)
  end
end
