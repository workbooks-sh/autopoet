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
    "narrator" =>
      "a warm, dry narrator in his forties, calm and quietly amused, like he is letting you in on a good secret",
    "sage" =>
      "an unhurried elder philosopher with a deep mellow voice and a slight british lilt, hypnotic musing storyteller cadence, a playful chuckle hiding at the edges of every sentence",
    "commander" =>
      "a deep gravelly commanding male voice, streetwise and effortlessly cool, punchy emphatic preacher-like delivery with dramatic pauses, radiating unshakable confidence",
    "spark" =>
      "a young bright bubbly social media girl, fast casual delivery with playful upspeak, sounds like she is hyping her best friend on camera, infectious energy"
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
