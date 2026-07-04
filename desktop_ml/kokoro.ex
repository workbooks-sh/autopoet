defmodule Autopoet.Kokoro do
  @moduledoc """
  BEAM-native Kokoro-82M text-to-speech on the ONNX lane — the same Ortex
  pattern as `Autopoet.Stt.Moonshine`: official graph in-process, no python,
  no browser downloads. This retires the widget's Web-Worker Kokoro as the
  primary voice; the worker remains only as a fallback when this engine is
  unavailable.

  Pipeline (mirrors kokoro-js / the Python reference):

    text ──espeak-ng──▶ IPA (with stress marks)
         ──vocab map──▶ token ids  (tokenizer.json's 115-char table)
         ──voice bin ──▶ style vector (voices/<name>.bin = [510][256] f32,
                         row indexed by token count)
         ──Ortex.run──▶ f32 waveform @24kHz ──▶ 16-bit WAV

  Files live under `data/models/kokoro/` (model_quantized.onnx, tokenizer.json,
  voices/*.bin) — downloaded once at build/dev time, nothing fetched at speak
  time. `espeak-ng` comes from Homebrew; without it the engine reports
  `{:error, :no_espeak}` and the widget falls back to its worker.
  """
  use GenServer

  @sr 24_000
  @max_ids 509

  # ── public API ─────────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "True when the model is loaded and espeak-ng is present."
  def ready? do
    GenServer.call(__MODULE__, :ready?, 1_000)
  catch
    :exit, _ -> false
  end

  @doc "\"ready\" | \"loading\" | \"off\" — the widget's boot probe."
  def status do
    cond do
      ready?() -> "ready"
      File.exists?(model_path()) -> "loading"
      true -> "off"
    end
  end

  @doc "Synthesize `text` → {:ok, wav_binary(16-bit mono 24kHz)} | {:error, reason}."
  def speak(text, voice \\ "af_heart") do
    GenServer.call(__MODULE__, {:speak, text, voice}, 30_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, nil, {:continue, :load}}

  @impl true
  def handle_continue(:load, _state) do
    engine = load_dir(dir())
    if engine, do: Autopoet.Log.puts("kokoro: voice engine up (BEAM-native, #{map_size(engine.voices)} voice(s))")
    {:noreply, engine}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state != nil and espeak?(), state}
  end

  def handle_call({:speak, _text, _voice}, _from, nil), do: {:reply, {:error, :not_ready}, nil}

  def handle_call({:speak, text, voice}, _from, engine) do
    {:reply, synth(engine, text, voice), engine}
  end

  # ── engine (pure — testable without the GenServer) ─────────────────────────

  def dir, do: Path.join([File.cwd!(), "data", "models", "kokoro"])
  defp model_path, do: Path.join(dir(), "model_quantized.onnx")

  @doc "Load the engine from a directory of shipped files (nil if absent)."
  def load_dir(dir) do
    model = Path.join(dir, "model_quantized.onnx")
    tok = Path.join(dir, "tokenizer.json")

    with true <- File.exists?(model),
         true <- File.exists?(tok),
         {:ok, vocab} <- read_vocab(tok),
         voices when map_size(voices) > 0 <- read_voices(Path.join(dir, "voices")) do
      %{model: Ortex.load(model), vocab: vocab, voices: voices}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp read_vocab(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"model" => %{"vocab" => vocab}}} <- Jason.decode(raw) do
      {:ok, vocab}
    else
      _ -> :error
    end
  end

  defp read_voices(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for f <- files, String.ends_with?(f, ".bin"), into: %{} do
          {Path.basename(f, ".bin"), File.read!(Path.join(dir, f))}
        end

      _ ->
        %{}
    end
  end

  @doc "Pure synthesis against a loaded engine."
  def synth(engine, text, voice) do
    with {:ok, style_bin} <- Map.fetch(engine.voices, voice) |> ok_or(:unknown_voice),
         {:ok, ipa} <- phonemize(text),
         ids when ids != [] <- token_ids(engine.vocab, ipa) do
      tokens = [0] ++ ids ++ [0]
      style = style_for(style_bin, length(ids))

      {wave} =
        Ortex.run(engine.model, {
          Nx.tensor([tokens], type: :s64),
          style,
          Nx.tensor([1.0], type: :f32)
        })

      {:ok, wav16(Nx.backend_transfer(wave) |> Nx.flatten())}
    else
      [] -> {:error, :nothing_to_say}
      {:error, _} = e -> e
    end
  rescue
    e -> {:error, {:synth, Exception.message(e) |> String.slice(0, 120)}}
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, why), do: {:error, why}

  # ── phonemization: espeak-ng IPA, punctuation re-woven between chunks ──────

  defp espeak?, do: System.find_executable("espeak-ng") != nil

  @doc false
  def phonemize(text) do
    if espeak?() do
      clean = text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 600)

      ipa =
        Regex.split(~r/([,;:.!?…—])/u, clean, include_captures: true, trim: true)
        |> Enum.map(fn chunk ->
          if Regex.match?(~r/^[,;:.!?…—]$/u, chunk) do
            chunk
          else
            case System.cmd("espeak-ng", ["-q", "--ipa", "-v", "en-us", chunk], stderr_to_stdout: true) do
              {out, 0} -> out |> String.split("\n", trim: true) |> Enum.join(" ") |> String.trim()
              _ -> ""
            end
          end
        end)
        |> Enum.join(" ")
        |> String.replace(~r/ +([,;:.!?…—])/u, "\\1")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      if ipa == "", do: {:error, :phonemize_empty}, else: {:ok, ipa}
    else
      {:error, :no_espeak}
    end
  end

  defp token_ids(vocab, ipa) do
    ipa
    |> String.graphemes()
    |> Enum.map(&Map.get(vocab, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_ids)
  end

  # voices/<name>.bin = 510 rows × 256 f32 (LE); the row is picked by token count
  defp style_for(bin, n_ids) do
    row = min(n_ids, 509)
    <<_::binary-size(row * 256 * 4), slice::binary-size(256 * 4), _::binary>> = bin
    Nx.from_binary(slice, :f32) |> Nx.reshape({1, 256})
  end

  # ── WAV (16-bit PCM mono @24kHz) ────────────────────────────────────────────

  defp wav16(wave) do
    pcm =
      wave
      |> Nx.clip(-1.0, 1.0)
      |> Nx.multiply(32767.0)
      |> Nx.as_type(:s16)
      |> Nx.to_binary()

    len = byte_size(pcm)

    <<"RIFF", 36 + len::32-little, "WAVE", "fmt ", 16::32-little, 1::16-little, 1::16-little,
      @sr::32-little, @sr * 2::32-little, 2::16-little, 16::16-little, "data",
      len::32-little>> <> pcm
  end
end
