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
    # ≤10 words: voice + use case. All fast-biased (pacing words skew slow).
    # CARTOON RULE: energy/cheer adjectives + youth/high pitch = cartoon; fast
    # is safe only on grounded adult timbres. ACCENT RULE: prompt-side accent
    # control is weak (owner-verified) — authentic accents come from the CLONE
    # lane (ref wav + transcript), not descriptions. Rejected personas are
    # deleted, not commented — the roster (data/voices/verdicts) is history.

    # ── accepted (owner, 2026-07-05) ──
    "narrator" => "Calm male forties voice, fast dry delivery, documentary narration.",
    "sage" => "Mellow elderly male voice, quick warm delivery, philosophical audiobooks.",
    "commander" => "Deep gravelly male voice, fast confident delivery, movie trailers.",
    "crisp" => "Crisp professional female voice, fast clear delivery, product explainers.",
    "noir" => "Low smoky female voice, brisk intimate delivery, late-night radio.",
    "anchor" => "Clear authoritative female voice, fast steady delivery, news reading.",
    "buddy" => "Friendly casual male voice, quick upbeat delivery, podcast banter.",
    "editor" => "Dry witty female voice, forties, brisk delivery, essay narration.",
    "captain" => "Weathered male voice, fifties, brisk calm delivery, aviation radio.",
    "velvet" => "Smooth low male voice, brisk gentle delivery, meditation guides.",
    "sterling" => "Deep British male voice, brisk confident delivery, luxury advertisements.",
    "rosalind" => "Warm British female voice, thirties, brisk delivery, garden shows.",
    "bondi" => "Laid-back Australian male voice, brisk delivery, surf commentary.",
    "magnolia" => "Sweet southern belle female voice, brisk charming delivery, hospitality videos.",
    "smooth" => "Smooth deep Black male voice, brisk soulful delivery, radio DJ.",

    # ── the drunk family (sozzled is good — variants try different angles) ──
    "sozzled" => "Slurring drunk male voice, wobbly cheerful delivery, pub stories.",
    "tipsy" => "Tipsy rambling male voice, loose slurred phrasing, bar storytelling.",
    "merry" => "Merry drunken male voice, laughing between words, tavern toasts.",
    "groggy" => "Groggy mumbling male voice, thick slurred delivery, closing-time confessions."
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
