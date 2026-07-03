defmodule Autopoet.Dictate do
  @moduledoc """
  Local speech-to-text for the notes drawer — the Moonshine seam `Autopoet.Voice`
  promised. Fully on-device: audio never leaves the machine and is deleted the
  moment it's transcribed.

  Pipeline: browser MediaRecorder blob (AAC/mp4 in WKWebView) → `afconvert` to
  16kHz mono WAV → Moonshine ONNX (`moonshine/base`) in the dedicated venv at
  `data/moonshine-venv` (python3.12; created with
  `python3.12 -m venv data/moonshine-venv && pip install useful-moonshine-onnx`).
  First call downloads the model into the HF cache; later calls are ~a second.
  """

  @doc "Transcribe raw audio bytes (m4a/mp4/wav/aiff). Returns {:ok, text} | {:error, reason}."
  def transcribe(bytes, ext) when is_binary(bytes) and byte_size(bytes) > 0 do
    if venv_ok?() do
      base = Path.join(System.tmp_dir!(), "apdict-#{System.unique_integer([:positive])}")
      src = base <> "." <> sanitize_ext(ext)
      wav = base <> ".wav"

      try do
        File.write!(src, bytes)

        with {_, 0} <-
               System.cmd("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, wav],
                 stderr_to_stdout: true
               ),
             {out, 0} <-
               System.cmd(python(), ["-c", script(), wav], stderr_to_stdout: true) do
          case out |> String.split("APDICT:", parts: 2) do
            [_, text] -> {:ok, text |> String.trim()}
            _ -> {:error, :no_transcript}
          end
        else
          {out, _} -> {:error, {:convert_or_stt, String.slice(out, 0, 200)}}
        end
      after
        File.rm(src)
        File.rm(wav)
      end
    else
      {:error, :stt_not_installed}
    end
  end

  def transcribe(_, _), do: {:error, :empty_audio}

  def venv_ok?, do: File.exists?(python())

  defp python, do: Path.join([Autopoet.Discovery.home(), "data", "moonshine-venv", "bin", "python"])

  # marker keeps model-download chatter on stdout from polluting the transcript
  defp script do
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
