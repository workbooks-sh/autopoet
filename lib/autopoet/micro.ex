defmodule Autopoet.Micro do
  @moduledoc """
  The resident micro-brain — a small local LLM (MiniCPM5-1B, Q8 GGUF via
  llama-server) that makes DEFINITIVE PROCEDURAL TOOL DECISIONS across the
  substrate. Net-new for autopoet (wb spike): NOT the planner (that stays
  OpenRouter/Gemini) and NOT a nominator (a 1B echoes lists instead of ranking —
  the shipped hashed embedder keeps that job). Its one proven skill is picking
  the correct next ACTION from a fixed toolset given a situation.

  ## Why a 1B here at all

  Two spike evals (`nexus/spike/*`) drew the line empirically:

    * `micro_nominator_eval` — semantic edge ranking: the 1B FAILS (parrots the
      candidate list). Mean P@3 on causal edges ~0.17 vs the zero-dep embedder's
      ~0.08 — within noise, not worth 1.3GB RSS. Verdict: keep `Nexus.Embed`.
    * `micro_triage_eval` — pick the first diagnostic action for a drift alarm:
      the 1B scores 4/4 decision + 4/4 format in no-think mode with a rigid
      template + one-shot. THIS is the fit.

  So `Autopoet.Micro` is deliberately narrow: `decide/3` maps a situation onto
  one of the caller's declared tools. Everything it touches is procedural and
  local — no world knowledge asked of it (its weak axis), no ranking.

  ## Money + containment posture

  The endpoint is localhost llama-server, so `Nexus.Llm`'s money boundary bills
  NO ONE (`local?/1` → free lane). The decision is ADVISORY: a `decide/3` result
  is a suggested action for a caller (shadow-layer triage, effect-retry routing)
  that still runs through whatever gate that caller already has. The micro-brain
  never mutates the body or merges a proposal — same containment rung as
  `Shadow.Hebb.recall/2` (ranking/suggestion only, worst case a worse suggestion).

  ## Operational mode

  NO-THINK, low temperature, tight `max_tokens`. Think mode over-runs simple
  decisions (0/4 in the eval — it narrates a `<think>` past the token budget and
  never emits the call). Fast, cheap, decisive is the whole point.
  """

  @default_url "http://127.0.0.1:8891/v1/chat/completions"
  @default_model "minicpm5"

  @doc "The configured local endpoint (localhost llama-server). Free lane."
  def url, do: Application.get_env(:autopoet, __MODULE__, [])[:url] || @default_url
  def model, do: Application.get_env(:autopoet, __MODULE__, [])[:model] || @default_model

  @doc """
  Is the local micro-model reachable? A cheap `/health` probe (llama-server
  exposes it). Callers gate on this and fall back to their non-micro path when
  it's down — the substrate must degrade to exactly today's behavior, never fail.
  """
  def available? do
    health = String.replace(url(), ~r{/v1/chat/completions/?$}, "/health")
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(health), []}, [timeout: 1_500], []) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Decide the next action. `situation` is a one-paragraph description; `tools` is a
  list of `%{name, arg_hint, desc}` (the fixed action vocabulary the caller can
  execute). Returns `{:ok, %{tool, arg, raw}}` with `tool` guaranteed to be one of
  the given tool names, or `:none` (model unreachable, or emitted nothing usable —
  caller falls back).

  `opts`:
    * `:example` — a one-shot `{situation, "CALL <tool> <arg>"}` demonstration.
      Strongly recommended: the 1B's format discipline is prompt-sensitive; the
      example is what turns narration into a parseable call (eval-proven).
    * `:max_tokens` — default 96 (a decision is one short line).
  """
  def decide(situation, tools, opts \\ []) when is_list(tools) and tools != [] do
    names = Enum.map(tools, & &1.name)

    messages = [
      %{role: "system", content: system_prompt(tools, opts[:example])},
      %{role: "user", content: "SITUATION: #{situation}\nWhat is your single next action?"}
    ]

    llm_opts = [
      base_url: url(),
      model: model(),
      tenant: nil,
      temperature: 0.3,
      max_tokens: opts[:max_tokens] || 96,
      # MiniCPM5 think/no-think rides llama.cpp's chat_template_kwargs passthrough
      # (Nexus.Llm forwards it). No-think = fast, decisive; think over-runs here.
      chat_template_kwargs: %{enable_thinking: false}
    ]

    case Nexus.Llm.complete(messages, llm_opts) do
      {:ok, %{content: content}} when is_binary(content) -> parse(content, names)
      _ -> :none
    end
  end

  # ── prompt (the eval-proven shape: rigid template + optional one-shot, ASCII) ──
  defp system_prompt(tools, example) do
    lines =
      Enum.map_join(tools, "\n", fn t ->
        "  CALL #{t.name} #{Map.get(t, :arg_hint, "<arg>")}    #{Map.get(t, :desc, "")}"
      end)

    base =
      "You are a substrate decision agent. Reply with ONE line only, no other text, " <>
        "format: CALL <tool> <arg>\n" <> lines

    case example do
      {sit, call} -> base <> "\n\nExample:\nSITUATION: #{sit}\n#{call}"
      _ -> base
    end
  end

  # ── parse: first well-formed CALL whose tool is in the allowed set ──
  defp parse(content, names) do
    visible = content |> String.replace(~r/<think>.*?<\/think>/s, "") |> String.trim()
    alt = Enum.map_join(names, "|", &Regex.escape/1)

    case Regex.run(~r/CALL\s+(#{alt})\b[ \t]*(.*)$/im, visible) do
      [_, tool, arg] -> {:ok, %{tool: tool, arg: String.trim(arg), raw: visible}}
      _ -> :none
    end
  end
end
