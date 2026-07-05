defmodule Autopoet.VoicePersonas do
  @moduledoc """
  DESIGNED voice personas — VoiceDesign descriptions, named. The premium
  voice's real power isn't preset speakers, it's voices from language; these
  are the house archetypes (owner-picked). Clients request
  `/voice/tts?engine=qwen-design&persona=<name>`; the description is resolved
  server-side so prompts stay canonical (and later, vault-editable — a
  persona doc the user owns, like the glossary).

  Archetypes, never impersonations: descriptions capture a VIBE, not a person.
  """

  @personas %{
    # ≤10 words each, EXPLICITLY simple: voice + use case, nothing ornate —
    # complexity drifts. NO slow-pacing words anywhere: pacing prompts skew
    # slow in practice, so every persona is prompted fast regardless of pitch.
    "narrator" => "Calm male forties voice, fast dry delivery, documentary narration.",
    "sage" => "Mellow elderly male voice, quick warm delivery, philosophical audiobooks.",
    "commander" => "Deep gravelly male voice, fast confident delivery, movie trailers.",
    "spark" => "Bright young female voice, fast cheerful delivery, social videos.",
    "crisp" => "Crisp professional female voice, fast clear delivery, product explainers.",
    "buddy" => "Friendly casual male voice, quick upbeat delivery, podcast banter.",
    "noir" => "Low smoky female voice, brisk intimate delivery, late-night radio.",
    "coach" => "Energetic male voice, fast motivating delivery, workout coaching.",
    "pixie" => "Cute high-pitched child voice, quick playful delivery, animation characters.",
    "anchor" => "Clear authoritative female voice, fast steady delivery, news reading."
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
