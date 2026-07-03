defmodule Autopoet.Stt do
  @moduledoc """
  BEAM-native speech-to-text — no python, no sidecars, nothing downloaded at
  transcribe time. Two in-process engines behind one door:

    * PRIMARY — Moonshine base on the ONNX lane (`Autopoet.Stt.Moonshine`,
      official UsefulSensors graphs via Ortex). Small, fast, ships with the app
      under `data/models/moonshine`.
    * FALLBACK — Whisper base on Bumblebee/EXLA, weights cached once under
      `data/models/bumblebee` (first boot or packaging pre-seed). Loaded lazily,
      only if moonshine is missing or errors.

  The primary engine warms in the background right after boot
  (`handle_continue`); calls that arrive mid-warmup queue behind it.
  """
  use GenServer

  @whisper "openai/whisper-base"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Transcribe a 16kHz mono s16le WAV file. Returns {:ok, text} | {:error, reason}."
  def transcribe_wav(path), do: GenServer.call(__MODULE__, {:stt, path}, 180_000)

  @doc "Which engine is live? :moonshine | :whisper | nil"
  def engine, do: GenServer.call(__MODULE__, :engine)

  @impl true
  def init(:ok), do: {:ok, %{moonshine: nil, whisper: nil}, {:continue, :warm}}

  @impl true
  def handle_continue(:warm, state) do
    moonshine = Autopoet.Stt.Moonshine.load(model_dir("moonshine"))

    # bind-run: onnxruntime's symbols must resolve BEFORE anything dlopens XLA
    # (both bundle protobuf/absl; XLA-first segfaults Ortex.run) — half a second
    # of silence through the encoder pins the symbol space to onnxruntime
    if moonshine, do: Autopoet.Stt.Moonshine.bind(moonshine)
    if moonshine == nil, do: Autopoet.Log.puts("stt: moonshine files absent — whisper will serve")
    {:noreply, %{state | moonshine: moonshine}}
  end

  @impl true
  def handle_call(:engine, _from, state) do
    {:reply, (state.moonshine && :moonshine) || (state.whisper && :whisper), state}
  end

  def handle_call({:stt, path}, _from, state) do
    case wav_tensor(path) do
      {:ok, audio} ->
        case moonshine(state, audio) do
          {:ok, _} = ok -> {:reply, ok, state}
          {:error, why} -> whisper_reply(state, audio, why)
        end

      {:error, _} = e ->
        {:reply, e, state}
    end
  end

  # ── moonshine (primary) ──────────────────────────────────────────────────────
  defp moonshine(%{moonshine: nil}, _audio), do: {:error, :moonshine_absent}

  defp moonshine(%{moonshine: engine}, audio) do
    Autopoet.Stt.Moonshine.transcribe(engine, Nx.reshape(audio, {1, Nx.size(audio)}))
  rescue
    e -> {:error, {:moonshine_crashed, Exception.message(e)}}
  end

  # ── whisper (fallback, lazy) ─────────────────────────────────────────────────
  defp whisper_reply(state, audio, primary_why) do
    serving = state.whisper || load_whisper()

    if serving do
      case Nx.Serving.run(serving, audio) do
        %{chunks: chunks} ->
          {:reply, {:ok, chunks |> Enum.map_join(" ", & &1.text) |> String.trim()},
           %{state | whisper: serving}}

        other ->
          {:reply, {:error, {:unexpected, other}}, %{state | whisper: serving}}
      end
    else
      {:reply, {:error, {:no_engine, primary_why}}, state}
    end
  rescue
    e -> {:reply, {:error, {:whisper_crashed, Exception.message(e)}}, state}
  end

  defp load_whisper do
    # the Nx runner (EXLA today, EMLX when it matures) starts HERE, lazily —
    # always after the ONNX lane has bound its symbols (bind-run in handle_continue)
    %{defn_options: defn_options} = Autopoet.Ml.runner_up!()
    dir = model_dir("bumblebee")
    File.mkdir_p!(dir)
    repo = {:hf, @whisper, cache_dir: dir}

    with {:ok, model} <- Bumblebee.load_model(repo),
         {:ok, featurizer} <- Bumblebee.load_featurizer(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo),
         {:ok, generation_config} <- Bumblebee.load_generation_config(repo) do
      Bumblebee.Audio.speech_to_text_whisper(model, featurizer, tokenizer, generation_config,
        compile: [batch_size: 1],
        defn_options: defn_options,
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

  defp model_dir(name), do: Path.join([Autopoet.Discovery.home(), "data", "models", name])

  # afconvert emits standard RIFF: walk the chunks to the `data` payload,
  # s16le mono 16k → f32 tensor in [-1, 1] (what both engines want)
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
