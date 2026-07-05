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
    # structure per the VoiceDesign guidance: identity → pitch/pace/timbre →
    # emotion → "suitable for…" anchor; 15–40 words; concrete adjectives only
    # (vague/metaphoric traits destabilize the voice). Iterate ONE dimension
    # at a time when tuning.
    "narrator" =>
      "A calm male voice in his forties, medium-low pitch, slow to moderate pace, dry and quietly amused, suitable for documentary narration.",
    "sage" =>
      "A gentle elderly male voice, low mellow pitch, slow unhurried pace with musing pauses, warm and contemplative, suitable for philosophical audiobook narration.",
    "commander" =>
      "A deep gravelly male voice in his forties, low pitch, punchy deliberate pace with dramatic pauses, confident and commanding, suitable for movie trailer voice-overs.",
    "spark" =>
      "A young lively female voice, early twenties, high pitch, fast speaking rate with rising intonation, cheerful and energetic, suitable for social media product videos."
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
