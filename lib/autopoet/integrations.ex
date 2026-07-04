defmodule Autopoet.Integrations do
  @moduledoc """
  Phase E (plan wb-h0tjs.6) — the execution lane that makes connected accounts
  EARN their place. The audit found the connection tokens had zero consumers and
  Composio.execute/2 had zero callers; this module is the missing half.

  Three lanes, each with an INJECTABLE transport (`:transport` opt) so the full
  path is eval-driven without a live account, and the same code runs live when a
  real token/key is present:

    E1 auth bridge + thin clients — `read/3` fetches a scoped resource from a
       connected provider (github repo readme, cloudflare zone facts, drive doc)
       using the user's `Autopoet.Connections` token. Consent-scoped: only what
       the caller names is read.
    E2 execute lane — `execute/2` dispatches a connected Composio tool; wired to
       the agent loop as the neutral `app.execute` effect (registered at boot),
       so a persona that connected Gmail/Notion gets an agent that can ACT.
    E3 reward ingestion — `settle_reward/1` turns a billing/usage event
       (Polar order, an app analytics signal) into a `reward.landed` bus event
       the Outcomes ledger already tallies — "the machine wants to make money"
       as deploy-time reward wiring, not a runtime opinion.
  """

  # ── E1: auth bridge + thin provider clients ─────────────────────────────────

  @doc """
  Read a scoped resource from a connected provider. `spec` names exactly what to
  fetch (e.g. `%{repo: "owner/name", resource: :readme}`). Returns
  `{:ok, text} | {:error, reason} | {:skip, :not_connected}`. `:transport` is an
  injectable `(request -> {:ok, body} | {:error, r})` for evals.
  """
  def read(provider, spec, opts \\ []) do
    token = token_for(provider, opts)

    cond do
      is_nil(token) -> {:skip, :not_connected}
      true -> do_read(provider, spec, token, transport(opts))
    end
  end

  defp do_read(:github, %{repo: repo, resource: :readme}, token, tport) do
    case tport.(%{method: :get, url: "https://api.github.com/repos/#{repo}/readme", token: token, provider: :github}) do
      {:ok, %{"content" => b64}} -> {:ok, Base.decode64!(String.replace(b64, "\n", ""))}
      {:ok, other} -> {:ok, inspect(other)}
      err -> err
    end
  end

  defp do_read(:cloudflare, %{zone: zone, resource: :facts}, token, tport) do
    case tport.(%{method: :get, url: "https://api.cloudflare.com/client/v4/zones/#{zone}", token: token, provider: :cloudflare}) do
      {:ok, %{"result" => r}} -> {:ok, "zone #{r["name"]} · status #{r["status"]} · ns #{inspect(r["name_servers"])}"}
      err -> err
    end
  end

  defp do_read(:google, %{doc: doc_id, resource: :text}, token, tport) do
    case tport.(%{method: :get, url: "https://www.googleapis.com/drive/v3/files/#{doc_id}/export?mimeType=text/plain", token: token, provider: :google}) do
      {:ok, %{"text" => t}} -> {:ok, t}
      {:ok, raw} when is_binary(raw) -> {:ok, raw}
      err -> err
    end
  end

  defp do_read(_p, _spec, _t, _tport), do: {:error, :unsupported_resource}

  # ── E2: Composio execute lane ───────────────────────────────────────────────

  @doc """
  Execute a connected tool. `:transport` overrides the Composio REST call (evals);
  live path is `Autopoet.Composio.execute/2`. Returns `{:ok, result} | {:error,
  reason} | {:skip, :not_configured}`.
  """
  def execute(action, arguments, opts \\ []) when is_binary(action) and is_map(arguments) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) ->
        fun.(action, arguments)

      _ ->
        if Autopoet.Composio.configured?(),
          do: Autopoet.Composio.execute(action, arguments),
          else: {:skip, :not_configured}
    end
  end

  @doc """
  The neutral `app.execute` effect — registered at boot so an agent/hook can act
  through a connected tool. Args: `%{action, arguments}`. Emits `app.executed`
  (status + action) so the outcome ledger and audit see every tool call. Never
  raises: a failed tool call settles, it doesn't crash the caller.
  """
  def install_effect do
    Nexus.Effects.register("app.execute", fn args, _event, _ctx ->
      action = to_string(args[:action] || args["action"] || "")
      arguments = args[:arguments] || args["arguments"] || %{}

      # a test/deploy may wire an execute transport via app env (no live key)
      opts =
        case Application.get_env(:autopoet, :execute_transport) do
          fun when is_function(fun, 2) -> [transport: fun]
          _ -> []
        end

      result =
        if action == "",
          do: {:error, :no_action},
          else: execute(action, arguments, opts)

      status = if match?({:ok, _}, result), do: :ok, else: :error
      Nexus.Events.emit(%{kind: "app.executed", action: action, status: status, tags: []})
      if status == :ok, do: :ok, else: :error
    end)
  end

  # ── E3: reward ingestion ────────────────────────────────────────────────────

  @doc """
  Settle an external reward (billing/usage) into the learning economy. `source`
  is `:polar | :analytics | :manual`; `amount` a positive number; `target` the
  locus/component credited. Emits `reward.landed` — the Outcomes ledger and the
  (future) credit ledger consume it. Deploy-time reward WIRING; the runtime stays
  neutral (the reward whitelist lives in frozen config, the cage).
  """
  def settle_reward(%{source: source, amount: amount, target: target} = ev) when amount > 0 do
    Nexus.Events.emit(%{
      kind: "reward.landed",
      source: to_string(source),
      amount: amount * 1.0,
      target: to_string(target),
      cause: ev[:cause],
      tags: []
    })

    :ok
  end

  def settle_reward(_), do: {:error, :invalid_reward}

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp token_for(provider, opts) do
    if Keyword.has_key?(opts, :token) do
      Keyword.get(opts, :token)
    else
      try do
        Autopoet.Connections.get(to_string(provider))
      rescue
        _ -> nil
      end
    end
  end

  # default live transport: a thin bearer GET over :httpc (github/cloudflare/
  # google all speak Bearer + JSON). Evals inject their own.
  defp transport(opts) do
    Keyword.get(opts, :transport, &live_get/1)
  end

  defp live_get(%{url: url, token: token, provider: provider}) do
    :inets.start()
    :ssl.start()

    auth =
      case provider do
        :cloudflare -> {~c"authorization", String.to_charlist("Bearer #{token}")}
        _ -> {~c"authorization", String.to_charlist("Bearer #{token}")}
      end

    headers = [auth, {~c"accept", ~c"application/json"}, {~c"user-agent", ~c"autopoet"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, code, _}, _, body}} when code in 200..299 ->
        {:ok, safe_json(to_string(body))}

      {:ok, {{_, code, _}, _, body}} ->
        {:error, {:http, code, String.slice(to_string(body), 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_json(s) do
    case Jason.decode(s) do
      {:ok, m} -> m
      _ -> s
    end
  end
end
