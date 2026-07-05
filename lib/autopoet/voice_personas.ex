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
    "velvet" => "Smooth low male voice, brisk gentle delivery, meditation guides.",

    # ── accent experiments (owner-requested) ──
    "albion" => "Refined British male voice, forties, brisk dry delivery, history documentaries.",
    "sterling" => "Deep British male voice, brisk confident delivery, luxury advertisements.",
    "rosalind" => "Warm British female voice, thirties, brisk delivery, garden shows.",
    "tempest" => "Sharp British female voice, brisk witty delivery, panel comedy.",
    "outback" => "Rugged Australian male voice, brisk friendly delivery, wildlife documentaries.",
    "bondi" => "Laid-back Australian male voice, brisk delivery, surf commentary.",
    "sheila" => "Bright Australian female voice, brisk warm delivery, travel vlogs.",
    "matilda" => "Confident Australian female voice, brisk delivery, cooking shows.",

    # ── character experiments (cartoon rule waived deliberately) ──
    "elder" => "Very old raspy male voice, quick frail delivery, folk tales.",
    "granny" => "Very old female voice, quick crackly delivery, fireside stories.",
    "robot" => "Monotone robotic synthetic voice, brisk precise delivery, computer announcements.",
    "sozzled" => "Slurring drunk male voice, wobbly cheerful delivery, pub stories.",

    # ── accent experiments round 2 (owner-requested) ──
    "smooth" => "Smooth deep Black male voice, brisk soulful delivery, radio DJ.",
    "verse" => "Warm Black male voice, rhythmic brisk delivery, spoken word.",
    "queen" => "Rich confident Black female voice, brisk delivery, talk shows.",
    "hype" => "Quick energetic Black male voice, urban inflection, street interviews.",
    "colonel" => "Folksy elderly southern gentleman voice, brisk drawl, chicken commercials.",
    "magnolia" => "Sweet southern belle female voice, brisk charming delivery, hospitality videos."
  }

  @doc "The description for a persona name, or nil."
  def description(name) when is_binary(name), do: @personas[String.downcase(name)]
  def description(_), do: nil

  @doc "All persona names (for pickers)."
  def names, do: Map.keys(@personas) |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
