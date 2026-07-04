defmodule Autopoet.Keys do
  @moduledoc """
  Provider keys, resolved through `Nexus.Secrets` (store-first, env-fallback) —
  the same audited seam typeaway uses. Never `System.get_env` directly; the dev
  injection point is `.env` sourced by run.sh.
  """
  def inception, do: Nexus.Secrets.get("INCEPTION_API_KEY")
  def openrouter, do: Nexus.Secrets.get("OPENROUTER_API_KEY")
  def gemini, do: Nexus.Secrets.get("GEMINI_API_KEY")
end

defmodule Autopoet.Providers do
  @moduledoc """
  The ONLY providers in play (no Groq, by decree), both through the `Nexus.Llm`
  money boundary, OpenAI-compatible with per-call base_url/key/model.

  GATEWAY-FIRST (owner decree, 2026-07-04): production traffic routes through
  the Workbooks Cloudflare AI Gateway — the same `CF_AIG_URL` + `CF_AIG_TOKEN`
  seam Nexus.Llm already speaks (compat endpoint, `{provider}/{model}` ids).
  When the gateway is configured, the planner/limb lane rides it; the DIRECT
  provider URLs below are the eval/dev fallback only.

    * **OpenRouter** — the PLANNER (`AUTOPOET_PLANNER_MODEL`, default
      `google/gemini-3.5-flash`) and the LIMB bodies (declared per-limb in
      limbs.work, e.g. `xiaomi/mimo-v2.5`, riding Nexus.Llm's OpenRouter default).
    * **Mercury 2 / Inception** — the DRAFTER (diffusion model writes full files;
      typeaway-proven). OpenRouter is the drafting fallback. Drafter stays
      direct until its gateway route is verified live against wb-dogfood.
  """
  @inception_url "https://api.inceptionlabs.ai/v1/chat/completions"
  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @mercury_model "mercury-2"
  @default_planner_model "google/gemini-3.5-flash"

  # `brain_live: false` (test config) is the MASTER kill for live providers:
  # keys sitting in a developer's shell env must never turn the suite live —
  # they were silently igniting real limb runs (LLM spend + wasm memory that
  # tripped the watchdog's VM halt mid-suite). Tests inject :brain_llm instead.
  def live?, do: Application.get_env(:autopoet, :brain_live, true)

  def mercury?(), do: live?() and is_binary(Autopoet.Keys.inception())
  def openrouter?(), do: live?() and is_binary(Autopoet.Keys.openrouter())

  def planner_model,
    do: System.get_env("AUTOPOET_PLANNER_MODEL") || @default_planner_model

  @doc "Is the Workbooks Cloudflare AI Gateway configured? (production posture)"
  def gateway?, do: Nexus.Secrets.has?("CF_AIG_URL") and Nexus.Secrets.has?("CF_AIG_TOKEN")

  def mercury(messages, opts \\ []),
    do: call(@inception_url, Autopoet.Keys.inception(), @mercury_model, messages, opts)

  def openrouter(messages, opts \\ []) do
    if gateway?() do
      call(
        Nexus.Secrets.get("CF_AIG_URL"),
        Nexus.Secrets.get("CF_AIG_TOKEN"),
        "openrouter/" <> planner_model(),
        messages,
        opts
      )
    else
      call(@openrouter_url, Autopoet.Keys.openrouter(), planner_model(), messages, opts)
    end
  end

  defp call(url, key, model, messages, opts) do
    Nexus.Llm.complete(
      messages,
      Keyword.merge([base_url: url, api_key: key, model: model, tenant: nil], opts)
    )
  end
end
