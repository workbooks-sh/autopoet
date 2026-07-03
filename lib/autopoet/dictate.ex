defmodule Autopoet.Dictate do
  @moduledoc """
  Local speech-to-text for the notes drawer. Fully on-device: audio never
  leaves the machine and is deleted the moment it's transcribed.

  Pipeline: browser MediaRecorder blob (AAC/mp4 in WKWebView) → `afconvert` to
  16kHz mono WAV → `Autopoet.Stt` (Whisper on Bumblebee/EXLA, BEAM-native, the
  shipped default — weights live under `data/models`, downloaded at boot, never
  at transcribe time). If a Moonshine venv exists at `data/moonshine-venv`
  (python3.12 + useful-moonshine-onnx) it serves as the fallback engine.
  """

  @doc "Transcribe raw audio bytes (m4a/mp4/wav/aiff). Returns {:ok, text} | {:error, reason}."
  def transcribe(bytes, ext) when is_binary(bytes) and byte_size(bytes) > 0 do
    base = Path.join(System.tmp_dir!(), "apdict-#{System.unique_integer([:positive])}")
    src = base <> "." <> sanitize_ext(ext)
    wav = base <> ".wav"

    try do
      File.write!(src, bytes)

      case System.cmd("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, wav],
             stderr_to_stdout: true
           ) do
        {_, 0} -> wav |> whisper() |> fallback(wav)
        {out, _} -> {:error, {:convert, String.slice(out, 0, 200)}}
      end
    after
      File.rm(src)
      File.rm(wav)
    end
  end

  def transcribe(_, _), do: {:error, :empty_audio}

  # ── engines: whisper (shipped, BEAM-native) first, moonshine venv second ────
  defp whisper(wav), do: Autopoet.Stt.transcribe_wav(wav)

  defp fallback({:ok, _} = ok, _wav), do: ok

  defp fallback({:error, why}, wav) do
    if venv_ok?() do
      case System.cmd(python(), ["-c", moonshine_script(), wav], stderr_to_stdout: true) do
        {out, 0} ->
          case String.split(out, "APDICT:", parts: 2) do
            [_, text] -> {:ok, String.trim(text)}
            _ -> {:error, {:whisper, why}}
          end

        _ ->
          {:error, {:whisper, why}}
      end
    else
      {:error, {:whisper, why}}
    end
  end

  def venv_ok?, do: File.exists?(python())

  defp python, do: Path.join([Autopoet.Discovery.home(), "data", "moonshine-venv", "bin", "python"])

  # marker keeps model chatter on stdout from polluting the transcript
  defp moonshine_script do
    """
    import sys
    from moonshine_onnx import transcribe
    print("APDICT:" + " ".join(transcribe(sys.argv[1], "moonshine/base")))
    """
  end

  defp sanitize_ext(ext) do
    case String.downcase(to_string(ext)) do
      e when e in ~w(m4a mp4 wav aiff aif caf) -> e
      _ -> "m4a"
    end
  end
end
