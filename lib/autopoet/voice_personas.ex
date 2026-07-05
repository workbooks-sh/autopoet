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

  # user-created personas live in data/voices/personas ("name description" per
  # line) — the roster's + new voice modal writes here. Customs shadow compiled.
  defp customs_path, do: Path.join([Autopoet.Discovery.home(), "data", "voices", "personas"])

  @doc "User-created personas as %{name => description}."
  def customs do
    case File.read(customs_path()) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, " ", parts: 2) do
            [name, desc] when desc != "" -> Map.put(acc, name, desc)
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc "Create/overwrite a user persona. Name: 2-24 chars of [a-z0-9-]."
  def add(name, desc) do
    name = name |> to_string() |> String.downcase() |> String.trim()
    desc = desc |> to_string() |> String.trim() |> String.slice(0, 220) |> String.replace("\n", " ")

    if Regex.match?(~r/^[a-z0-9-]{2,24}$/, name) and desc != "" do
      c = Map.put(customs(), name, desc)
      File.mkdir_p!(Path.dirname(customs_path()))
      File.write!(customs_path(), Enum.map_join(c, "\n", fn {k, d} -> "#{k} #{d}" end) <> "\n")
      {:ok, name}
    else
      {:error, :bad_name_or_desc}
    end
  end

  @doc "The description for a persona name (customs shadow compiled), or nil."
  def description(name) when is_binary(name) do
    n = String.downcase(name)
    customs()[n] || @personas[n]
  end

  def description(_), do: nil

  @doc "All persona names (compiled + custom)."
  def names, do: (Map.keys(@personas) ++ Map.keys(customs())) |> Enum.uniq() |> Enum.sort()

  @doc "The default persona — the session voice when none is chosen."
  def default, do: "narrator"
end
