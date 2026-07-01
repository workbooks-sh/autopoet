defmodule Autopoet.Keys do
  @moduledoc """
  Provider keys, resolved through `Nexus.Secrets` (store-first, env-fallback) —
  the same audited seam typeaway uses. Never `System.get_env` directly; the dev
  injection point is `.env` sourced by run.sh.
  """
  def groq, do: Nexus.Secrets.get("GROQ_API_KEY")
  def inception, do: Nexus.Secrets.get("INCEPTION_API_KEY")
  def openrouter, do: Nexus.Secrets.get("OPENROUTER_API_KEY")
end

defmodule Autopoet.Providers do
  @moduledoc """
  Three cheap-and-capable providers through the `Nexus.Llm` money boundary, all
  OpenAI-compatible with per-call base_url/key/model:

    * **OpenRouter** — the PLANNER; model is a knob (`AUTOPOET_PLANNER_MODEL`,
      default `google/gemini-3.5-flash` — fast, multimodal, cheap). Swapping
      planners (MiniMax, Gemini, whatever's next) is an env var, not a code change.
    * **Mercury 2 / Inception** — the DRAFTER (diffusion model writes full files;
      typeaway-proven).
    * **Groq (llama-3.1-8b-instant)** — the fast FALLBACK for either role.
  """
  @groq_url "https://api.groq.com/openai/v1/chat/completions"
  @inception_url "https://api.inceptionlabs.ai/v1/chat/completions"
  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @groq_model "llama-3.1-8b-instant"
  @mercury_model "mercury-2"
  @default_planner_model "google/gemini-3.5-flash"

  def groq?(), do: is_binary(Autopoet.Keys.groq())
  def mercury?(), do: is_binary(Autopoet.Keys.inception())
  def openrouter?(), do: is_binary(Autopoet.Keys.openrouter())

  def planner_model,
    do: System.get_env("AUTOPOET_PLANNER_MODEL") || @default_planner_model

  def groq(messages, opts \\ []),
    do: call(@groq_url, Autopoet.Keys.groq(), @groq_model, messages, opts)

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
