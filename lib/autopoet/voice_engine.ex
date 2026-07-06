defmodule Autopoet.VoiceEngine do
  @moduledoc """
  DEV TOGGLE — which TTS engine /voice/tts speaks through:

    * "qwen"   (default): the premium local clone/persona voice (Qwen3-TTS, the
                product engine — expressive, per-owner cloned voices, ~0.8s
                streaming first-audio).
    * "kokoro" (comparison): the tiny BEAM-native Kokoro-82M (fixed preset
                voices, no personas/cloning, but ~0.3-0.5s and rock steady).

  Switch WITHOUT recompiling: set `WB_VOICE=kokoro` in the environment, OR write
  "kokoro"/"qwen" to `data/voice-engine` (POST /voice/engine?e=kokoro flips it).
  Env wins if present. Qwen stays the product default; this is a dev A/B lens.
  """

  @valid ~w(qwen kokoro)

  def current do
    env = System.get_env("WB_VOICE")

    cond do
      env in @valid ->
        env

      true ->
        case File.read(path()) do
          {:ok, v} when is_binary(v) -> if String.trim(v) in @valid, do: String.trim(v), else: "qwen"
          _ -> "qwen"
        end
    end
  end

  def kokoro?, do: current() == "kokoro"

  def set(e) when e in @valid do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), e <> "\n")
    :ok
  end

  def set(_), do: {:error, :bad_engine}

  defp path, do: Path.join([Autopoet.Discovery.home(), "data", "voice-engine"])

  @doc """
  Map a paired persona (or accent hint) to one of Kokoro's 3 preset voices.
  Kokoro can't clone, so this just picks the closest preset timbre.
  """
  @kokoro_voices ~w(bf_emma af_heart am_santa)

  def kokoro_voice(name) do
    n = String.downcase(to_string(name || ""))

    cond do
      # already an explicit Kokoro preset (the designer passes these) → use it.
      # matches the Kokoro naming convention <accent><gender>_<name>
      # (af_bella, am_onyx, bf_emma, bm_george …) so ALL installed voices pass,
      # not just the original trio.
      n in @kokoro_voices or Regex.match?(~r/^[a-z][fm]_[a-z]+$/, n) ->
        n

      true ->
        desc = String.downcase(to_string(Autopoet.VoicePersonas.description(name) || ""))
        blob = n <> " " <> desc
        if String.contains?(blob, ["male", "deep", "commander", "sterling", "gravelly", "man"]),
          do: "am_santa",
          else: "bf_emma"
    end
  end

  # Voice PSEUDONYMS — the designer shows a timbre descriptor, not the raw
  # Kokoro id (af_bella …). Showing the id risks a name collision with the
  # Autopoet's own name; a descriptor ("Rich Alto") reads as a voice, not a
  # second name. First letter of the id = accent → flag.
  @voice_labels %{
    "af_heart" => "Warm Mezzo",
    "af_bella" => "Rich Alto",
    "af_nicole" => "Soft Whisper",
    "af_sarah" => "Clear Mezzo",
    "af_sky" => "Bright Soprano",
    "af_aoede" => "Smooth Alto",
    "af_kore" => "Crisp Soprano",
    "am_santa" => "Jolly Bass",
    "am_adam" => "Firm Baritone",
    "am_michael" => "Warm Baritone",
    "am_onyx" => "Deep Bass",
    "am_puck" => "Playful Tenor",
    "bf_emma" => "Refined Mezzo",
    "bf_alice" => "Gentle Alto",
    "bf_isabella" => "Elegant Mezzo",
    "bf_lily" => "Sweet Soprano",
    "bm_george" => "Distinguished Bass",
    "bm_lewis" => "Mellow Baritone",
    "bm_fable" => "Storyteller Tenor"
  }

  @flags %{
    "a" => "🇺🇸",
    "b" => "🇬🇧",
    "e" => "🇪🇸",
    "f" => "🇫🇷",
    "h" => "🇮🇳",
    "i" => "🇮🇹",
    "j" => "🇯🇵",
    "p" => "🇧🇷",
    "z" => "🇨🇳"
  }

  @doc """
  The designer's voice picker list: `[%{id, label}]` for every installed
  Kokoro voice, label = flag + timbre descriptor. Sorted by id so accents group.
  """
  def catalog do
    dir = Path.join([Autopoet.Discovery.home(), "data", "models", "kokoro", "voices"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".bin"))
        |> Enum.map(&String.trim_trailing(&1, ".bin"))
        |> Enum.sort()
        |> Enum.map(fn id -> %{id: id, label: label(id)} end)

      _ ->
        []
    end
  end

  defp label(id) do
    flag = Map.get(@flags, String.first(id) || "", "")
    name = Map.get(@voice_labels, id, prettify(id))
    String.trim("#{flag} #{name}")
  end

  # unknown voice → a readable fallback from the id ("af_river" → "River")
  defp prettify(id) do
    id
    |> String.split("_")
    |> List.last()
    |> String.capitalize()
  end
end
