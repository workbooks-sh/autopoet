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
    # ≤10 words: voice + use case, nothing ornate. All prompted fast/brisk —
    # pacing words skew slow in practice. CARTOON RULE (learned): energy/cheer
    # adjectives (cute, playful, cheerful, upbeat, bright) combined with youth
    # or high pitch produce cartoon voices — "fast" is safe ONLY on grounded
    # adult timbres. No british lilt, nothing childish or high-pitched.

    # ── accepted (owner, 2026-07-05) ──
    "narrator" => "Calm male forties voice, fast dry delivery, documentary narration.",
    "sage" => "Mellow elderly male voice, quick warm delivery, philosophical audiobooks.",
    "commander" => "Deep gravelly male voice, fast confident delivery, movie trailers.",
    "crisp" => "Crisp professional female voice, fast clear delivery, product explainers.",
    "noir" => "Low smoky female voice, brisk intimate delivery, late-night radio.",
    "anchor" => "Clear authoritative female voice, fast steady delivery, news reading.",
    "buddy" => "Friendly casual male voice, quick upbeat delivery, podcast banter.",

    # ── candidates (replacing pixie/coach/spark — grounded, varied) ──
    "baritone" => "Rich baritone male voice, brisk vivid delivery, fiction audiobooks.",
    "editor" => "Dry witty female voice, forties, brisk delivery, essay narration.",
    "captain" => "Weathered male voice, fifties, brisk calm delivery, aviation radio.",
    "velvet" => "Smooth low male voice, brisk gentle delivery, meditation guides."
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
