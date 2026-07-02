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
  money boundary, OpenAI-compatible with per-call base_url/key/model:

    * **OpenRouter** — the PLANNER (`AUTOPOET_PLANNER_MODEL`, default
      `google/gemini-3.5-flash`) and the LIMB bodies (declared per-limb in
      limbs.work, e.g. `xiaomi/mimo-v2.5`, riding Nexus.Llm's OpenRouter default).
    * **Mercury 2 / Inception** — the DRAFTER (diffusion model writes full files;
      typeaway-proven). OpenRouter is the drafting fallback.
  """
  @inception_url "https://api.inceptionlabs.ai/v1/chat/completions"
  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @mercury_model "mercury-2"
  @default_planner_model "google/gemini-3.5-flash"

  def mercury?(), do: is_binary(Autopoet.Keys.inception())
  def openrouter?(), do: is_binary(Autopoet.Keys.openrouter())

  def planner_model,
    do: System.get_env("AUTOPOET_PLANNER_MODEL") || @default_planner_model

  def mercury(messages, opts \\ []),
    do: call(@inception_url, Autopoet.Keys.inception(), @mercury_model, messages, opts)

  def openrouter(messages, opts \\ []),
    do: call(@openrouter_url, Autopoet.Keys.openrouter(), planner_model(), messages, opts)

  defp call(url, key, model, messages, opts) do
    Nexus.Llm.complete(
      messages,
      Keyword.merge([base_url: url, api_key: key, model: model, tenant: nil], opts)
    )
  end
end
