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
  def kokoro_voice(name) do
    n = String.downcase(to_string(name || ""))
    desc = String.downcase(to_string(Autopoet.VoicePersonas.description(name) || ""))
    blob = n <> " " <> desc

    cond do
      String.contains?(blob, ["male", "deep", "commander", "sterling", "gravelly", "man"]) -> "am_santa"
      true -> "bf_emma"
    end
  end
end
