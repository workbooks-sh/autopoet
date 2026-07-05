defmodule Autopoet.QwenTts do
  @moduledoc """
  The PREMIUM local voice — Qwen3-TTS 1.7B-CustomVoice (4-bit, MLX) behind a
  persistent python sidecar (priv/qwen_tts/serve.py). Spike-proven on this
  hardware: 1.83x realtime, correct-length speech, ~5.4GB peak (the 0.6B-4bit
  is collapsed — do not ship it). Kokoro stays the instant default engine;
  this one adds instruction-directed delivery (`instruct:` — "warmer, slower,
  conspiratorial…") and 10 languages.

  HEAVY: the sidecar is NOT booted at app start. `ensure/0` spawns it on first
  request (model load ~10-30s); it then stays resident. `speak/3` queues
  serially through the GenServer — at 1.83x RT, clause-staggered clips (the
  perform() pipeline) stay ahead of playback.

  Files: venv at data/qwen-tts-venv (priv/qwen_tts/setup.sh builds it);
  weights via the HF cache on first load.
  """
  use GenServer
  require Logger

  @timeout 120_000
  # one resident model at a time; ensure(:design) recycles the sidecar onto it
  @models %{
    custom: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
    design: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
    base: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
  }
  # fresh process every N generations — quality drifts on a long-lived sidecar
  # (fresh-boot takes A/B'd clearly better); recycled between utterances only
  @recycle_after 6

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "\"ready\" | \"loading\" | \"off\" — mirrors Kokoro.status/0."
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    :exit, _ -> "off"
  end

  def ready?, do: status() == "ready"

  @doc """
  Boot the sidecar if it isn't running (async — poll status/0). GENTLE: if a
  model is already resident, ensure/1 keeps it (a default boot from a client
  must never stomp a deliberately-loaded model). Explicit switching = switch/1.
  """
  def ensure(model \\ :custom), do: GenServer.cast(__MODULE__, {:ensure, model, false})

  @doc "Switch to `model`, recycling the sidecar if a different one is resident."
  def switch(model), do: GenServer.cast(__MODULE__, {:ensure, model, true})

  @doc "The resident model (:custom | :design) — resident or booting."
  def model do
    GenServer.call(__MODULE__, :model, 1_000)
  catch
    :exit, _ -> nil
  end

  @doc "Synthesize. Returns {:ok, wav_binary} | {:error, reason}. Boots on demand."
  def speak(text, voice \\ "Ryan", instruct \\ nil) do
    GenServer.call(__MODULE__, {:speak, %{text: text, voice: voice, instruct: instruct}}, @timeout)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  Zero-shot CLONE (Base model): speak `text` in the voice of `ref_wav_path`
  (+ its exact transcript). No weights, no training — the clip IS the voice.
  """
  def clone(text, ref_wav_path, ref_text) do
    GenServer.call(__MODULE__, {:speak, %{text: text, ref_audio: ref_wav_path, ref_text: ref_text}}, @timeout)
  catch
    :exit, _ -> {:error, :timeout}
  end

  # ── server ───────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, %{port: nil, ready: false, seq: 0, waiting: %{}, buf: "", model: :custom, gens: 0}}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply, (s.ready && "ready") || (s.port && "loading") || "off", s}
  end

  def handle_call(:model, _from, s), do: {:reply, (s.port && s.model) || nil, s}

  def handle_call({:speak, %{} = req0}, from, s) do
    s = boot(s, s.model)

    case s.port do
      nil ->
        {:reply, {:error, :no_venv}, s}

      port ->
        id = s.seq + 1
        Port.command(port, Jason.encode!(Map.put(req0, :id, id)) <> "\n")
        {:noreply, %{s | seq: id, waiting: Map.put(s.waiting, id, from)}}
    end
  end

  @impl true
  def handle_cast({:ensure, model, force}, s) do
    cond do
      s.port != nil and model != s.model and force ->
        # explicit switch: recycle onto the requested model
        Port.close(s.port)
        {:noreply, boot(%{s | port: nil, ready: false, buf: "", model: model}, model)}

      s.port != nil ->
        # resident model stays — gentle ensure never stomps it
        {:noreply, s}

      true ->
        {:noreply, boot(%{s | model: model}, model)}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = s) do
    {lines, buf} = split_lines(s.buf <> chunk)
    {:noreply, Enum.reduce(lines, %{s | buf: buf}, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    Logger.warning("qwen-tts sidecar exited (#{code})")
    for {_, from} <- s.waiting, do: GenServer.reply(from, {:error, :engine_died})
    {:noreply, %{s | port: nil, ready: false, waiting: %{}, buf: ""}}
  end

  def handle_info(_, s), do: {:noreply, s}

  # ── internals ────────────────────────────────────────────────────────────

  defp boot(%{port: port} = s, _model) when port != nil, do: s

  defp boot(s, model) do
    python = Path.join([Autopoet.Discovery.home(), "data", "qwen-tts-venv", "bin", "python"])
    script = Path.join([:code.priv_dir(:autopoet), "qwen_tts", "serve.py"])

    if File.exists?(python) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          args: [script],
          env: [
            {~c"PYTHONUNBUFFERED", ~c"1"},
            {~c"QWEN_TTS_MODEL", String.to_charlist(@models[model] || @models.custom)}
          ]
        ])

      Autopoet.Log.puts("qwen-tts: sidecar booting (#{model}, 1.7B-4bit, MLX)")
      %{s | port: port, model: model, gens: 0}
    else
      s
    end
  end

  # quality drifts over a long-lived process — recycle while IDLE (queue empty)
  # so the next utterance meets a fresh engine with no user-visible gap
  defp maybe_recycle(%{gens: g, waiting: w, port: port} = s)
       when g >= @recycle_after and map_size(w) == 0 and port != nil do
    Autopoet.Log.puts("qwen-tts: idle recycle after #{g} generations")
    Port.close(port)
    boot(%{s | port: nil, ready: false, buf: ""}, s.model)
  end

  defp maybe_recycle(s), do: s

  defp handle_line(line, s) do
    case Jason.decode(line) do
      {:ok, %{"ready" => true, "model" => m}} ->
        Autopoet.Log.puts("qwen-tts: ready (#{m})")
        %{s | ready: true}

      {:ok, %{"id" => id, "path" => path} = r} ->
        s = %{s | gens: s.gens + 1}

        maybe_recycle(reply(s, id, fn ->
          case File.read(path) do
            {:ok, wav} ->
              File.rm(path)
              Logger.debug("qwen-tts: #{r["dur"]}s in #{r["ms"]}ms")
              {:ok, wav}

            _ ->
              {:error, :wav_missing}
          end
        end))

      {:ok, %{"id" => id, "error" => err}} ->
        reply(s, id, fn -> {:error, err} end)

      _ ->
        s
    end
  end

  defp reply(s, id, fun) do
    case Map.pop(s.waiting, id) do
      {nil, _} -> s
      {from, waiting} -> GenServer.reply(from, fun.()) && %{s | waiting: waiting}
    end
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {rest, lines} = List.pop_at(parts, -1)
    {lines, rest || ""}
  end
end
