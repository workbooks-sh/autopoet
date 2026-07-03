defmodule Autopoet.Stt do
  @moduledoc """
  BEAM-native speech-to-text — Whisper running IN-PROCESS via Bumblebee/EXLA.
  The first taste of the future-state ML stack (everything on Nx, no python,
  no sidecar processes).

  Weights live under `data/models/bumblebee` and are fetched ONCE — at first
  boot (or pre-seeded by packaging), never at transcribe time. The serving is
  loaded and XLA-compiled in the background right after boot (`handle_continue`),
  so by the time anyone presses the mic it answers in about a second. Calls that
  arrive mid-warmup simply queue behind it.
  """
  use GenServer

  @model "openai/whisper-base"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Transcribe a 16kHz mono s16le WAV file. Returns {:ok, text} | {:error, reason}."
  def transcribe_wav(path), do: GenServer.call(__MODULE__, {:stt, path}, 180_000)

  @doc "Is the serving loaded and compiled?"
  def ready?, do: GenServer.call(__MODULE__, :ready?)

  @impl true
  def init(:ok), do: {:ok, nil, {:continue, :warm}}

  @impl true
  def handle_continue(:warm, nil) do
    {:noreply, load()}
  end

  @impl true
  def handle_call(:ready?, _from, serving), do: {:reply, serving != nil, serving}

  def handle_call({:stt, path}, _from, serving) do
    serving = serving || load()

    reply =
      with {:ok, serving} <- (serving && {:ok, serving}) || {:error, :stt_unavailable},
           {:ok, audio} <- wav_tensor(path) do
        case Nx.Serving.run(serving, audio) do
          %{chunks: chunks} -> {:ok, chunks |> Enum.map_join(" ", & &1.text) |> String.trim()}
          other -> {:error, {:unexpected, other}}
        end
      end

    {:reply, reply, serving}
  rescue
    e -> {:reply, {:error, {:stt_crashed, Exception.message(e)}}, serving}
  end

  # ── loading ──────────────────────────────────────────────────────────────────
  defp load do
    dir = Path.join([Autopoet.Discovery.home(), "data", "models", "bumblebee"])
    File.mkdir_p!(dir)
    repo = {:hf, @model, cache_dir: dir}

    with {:ok, model} <- Bumblebee.load_model(repo),
         {:ok, featurizer} <- Bumblebee.load_featurizer(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo),
         {:ok, generation_config} <- Bumblebee.load_generation_config(repo) do
      Bumblebee.Audio.speech_to_text_whisper(model, featurizer, tokenizer, generation_config,
        compile: [batch_size: 1],
        defn_options: [compiler: EXLA],
        chunk_num_seconds: 30
      )
    else
      err ->
        Autopoet.Log.puts("stt: whisper load failed #{inspect(err)}")
        nil
    end
  rescue
    e ->
      Autopoet.Log.puts("stt: whisper load crashed #{Exception.message(e)}")
      nil
  end

  # afconvert emits standard RIFF: walk the chunks to the `data` payload,
  # s16le mono 16k → f32 tensor in [-1, 1] (what the whisper featurizer wants)
  defp wav_tensor(path) do
    with {:ok, <<"RIFF", _::32-little, "WAVE", rest::binary>>} <- File.read(path),
         {:ok, pcm} <- wav_data(rest) do
      {:ok, pcm |> Nx.from_binary(:s16) |> Nx.as_type(:f32) |> Nx.divide(32_768.0)}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_wav}
    end
  end

  defp wav_data(<<"data", size::32-little, data::binary-size(size), _::binary>>), do: {:ok, data}

  defp wav_data(<<_id::binary-size(4), size::32-little, _::binary-size(size), rest::binary>>),
    do: wav_data(rest)

  defp wav_data(_), do: {:error, :no_data_chunk}
end
