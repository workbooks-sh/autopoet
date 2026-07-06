defmodule Autopoet.QwenTts do
  @moduledoc """
  The PREMIUM local voice — Qwen3-TTS 1.7B (4-bit, MLX) behind a POOL of
  persistent python sidecars (priv/qwen_tts/serve.py). Spike-proven on this
  hardware: ~1.5x realtime per worker (the 0.6B-4bit is collapsed — never
  ship it). Instruction-directed delivery (`instruct:`), zero-shot cloning
  (`clone/3`), 10 languages.

  POOLED: narration is sentence-pipelined (perform() fires every clip at
  once), so TWO workers synthesize consecutive sentences CONCURRENTLY — the
  clip for sentence N+1 lands while N is still playing. Requests go to the
  least-busy worker; determinism per clip is preserved (seeds are computed
  in-process per request, not per worker).

  WARM AT LAUNCH: init boots the DEFAULT voice's model with the app, so the
  first line never pays a model load.

  Files: venv at data/qwen-tts-venv (priv/qwen_tts/setup.sh builds it);
  weights via the HF cache on first load.
  """
  use GenServer
  require Logger

  @timeout 120_000
  @pool 2
  # one resident model at a time; switch/1 recycles the pool onto another
  @models %{
    custom: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
    design: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
    base: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
  }
  # fresh processes after N generations — but ONLY after a real idle gap
  # (mid-conversation recycles caused latency spikes + voice inconsistency)
  @recycle_after 24
  @recycle_idle_ms 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "\"ready\" | \"loading\" | \"off\" — mirrors Kokoro.status/0."
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    :exit, _ -> "off"
  end

  def ready?, do: status() == "ready"

  @doc """
  Boot the pool if it isn't running (async — poll status/0). GENTLE: if a
  model is already resident, ensure/1 keeps it (a default boot from a client
  must never stomp a deliberately-loaded model). Explicit switching = switch/1.
  """
  def ensure(model \\ :custom), do: GenServer.cast(__MODULE__, {:ensure, model, false})

  @doc "Switch to `model`, recycling the pool if a different one is resident."
  def switch(model), do: GenServer.cast(__MODULE__, {:ensure, model, true})

  @doc "The resident model (:custom | :design | :base) — resident or booting."
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
  #
  # state:
  #   workers  %{port => %{buf: binary, ready: bool}}
  #   assigns  %{id => port}     — which worker owns each in-flight request
  #   waiting  %{id => from}
  #   seq, model, gens

  @impl true
  def init(:ok) do
    # WARM AT LAUNCH: the default voice's model loads with the app, not when
    # the first line needs it (owner: latency must not include model boots)
    send(self(), :boot_default)
    {:ok, %{workers: %{}, assigns: %{}, waiting: %{}, seq: 0, model: :custom, gens: 0}}
  end

  @impl true
  def handle_call(:status, _from, s) do
    cond do
      Enum.any?(s.workers, fn {_, w} -> w.ready end) -> {:reply, "ready", s}
      map_size(s.workers) > 0 -> {:reply, "loading", s}
      true -> {:reply, "off", s}
    end
  end

  def handle_call(:model, _from, s), do: {:reply, (map_size(s.workers) > 0 && s.model) || nil, s}

  def handle_call({:speak, %{} = req0}, from, s) do
    s = boot(s, s.model)

    case least_busy(s) do
      nil ->
        {:reply, {:error, :no_venv}, s}

      port ->
        id = s.seq + 1
        Port.command(port, Jason.encode!(Map.put(req0, :id, id)) <> "\n")

        {:noreply,
         %{s | seq: id, waiting: Map.put(s.waiting, id, from), assigns: Map.put(s.assigns, id, port)}}
    end
  end

  @impl true
  def handle_cast({:ensure, model, force}, s) do
    cond do
      map_size(s.workers) > 0 and model != s.model and force ->
        # explicit switch: recycle the pool onto the requested model
        for {port, _} <- s.workers, do: Port.close(port)
        {:noreply, boot(%{s | workers: %{}, assigns: %{}, model: model}, model)}

      map_size(s.workers) > 0 ->
        # resident model stays — gentle ensure never stomps it
        {:noreply, s}

      true ->
        {:noreply, boot(%{s | model: model}, model)}
    end
  end

  @impl true
  def handle_info(:boot_default, s) do
    model =
      case File.read(Path.join([Autopoet.Discovery.home(), "data", "voices", "default"])) do
        {:ok, d} ->
          case String.split(String.trim(d), " ", parts: 2) do
            ["qwen-clone", _] -> :base
            ["qwen-design", _] -> :design
            _ -> :custom
          end

        _ ->
          :custom
      end

    {:noreply, boot(s, model)}
  end

  def handle_info({port, {:data, chunk}}, s) do
    case s.workers[port] do
      nil ->
        {:noreply, s}

      w ->
        {lines, buf} = split_lines(w.buf <> chunk)
        s = put_in(s.workers[port].buf, buf)
        {:noreply, Enum.reduce(lines, s, &handle_line(&1, &2, port))}
    end
  end

  def handle_info({:idle_recycle, seq_then}, s) do
    # recycle ONLY if not a single generation happened during the idle window
    if s.seq == seq_then and map_size(s.waiting) == 0 and map_size(s.workers) > 0 do
      Autopoet.Log.puts("qwen-tts: idle recycle after #{s.gens} generations (60s quiet)")
      for {port, _} <- s.workers, do: Port.close(port)
      {:noreply, boot(%{s | workers: %{}, assigns: %{}}, s.model)}
    else
      {:noreply, s}
    end
  end

  def handle_info({port, {:exit_status, code}}, s) do
    if Map.has_key?(s.workers, port) do
      Logger.warning("qwen-tts worker exited (#{code})")
      # fail ONLY this worker's in-flight requests; the twin keeps serving
      {dead, live} = Enum.split_with(s.assigns, fn {_, p} -> p == port end)

      waiting =
        Enum.reduce(dead, s.waiting, fn {id, _}, acc ->
          case Map.pop(acc, id) do
            {nil, rest} -> rest
            {from, rest} -> GenServer.reply(from, {:error, :engine_died}) && rest
          end
        end)

      {:noreply, %{s | workers: Map.delete(s.workers, port), assigns: Map.new(live), waiting: waiting}}
    else
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # ── internals ────────────────────────────────────────────────────────────

  defp boot(s, _model) when map_size(s.workers) > 0, do: s

  defp boot(s, model) do
    python = Path.join([Autopoet.Discovery.home(), "data", "qwen-tts-venv", "bin", "python"])
    script = Path.join([:code.priv_dir(:autopoet), "qwen_tts", "serve.py"])

    if File.exists?(python) do
      workers =
        for _ <- 1..@pool, into: %{} do
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

          {port, %{buf: "", ready: false}}
        end

      Autopoet.Log.puts("qwen-tts: pool booting (#{map_size(workers)}× #{model}, 1.7B-4bit, MLX)")
      %{s | workers: workers, model: model, gens: 0}
    else
      s
    end
  end

  # the worker with the fewest in-flight requests (ready workers preferred)
  defp least_busy(s) do
    load = Enum.frequencies(Map.values(s.assigns))

    s.workers
    |> Enum.sort_by(fn {port, w} -> {!w.ready, Map.get(load, port, 0)} end)
    |> case do
      [{port, _} | _] -> port
      [] -> nil
    end
  end

  # quality drifts over a long-lived process — but recycling mid-conversation
  # trades drift for stalls. Schedule a check after a REAL idle window; only
  # recycle if nothing spoke in the meantime.
  defp maybe_recycle(%{gens: g, waiting: w} = s)
       when g >= @recycle_after and map_size(w) == 0 do
    if map_size(s.workers) > 0, do: Process.send_after(self(), {:idle_recycle, s.seq}, @recycle_idle_ms)
    s
  end

  defp maybe_recycle(s), do: s

  defp handle_line(line, s, port) do
    case Jason.decode(line) do
      {:ok, %{"ready" => true, "model" => m}} ->
        unless Enum.any?(s.workers, fn {_, w} -> w.ready end),
          do: Autopoet.Log.puts("qwen-tts: ready (#{m})")

        put_in(s.workers[port].ready, true)

      {:ok, %{"id" => id, "path" => path} = r} ->
        s = %{s | gens: s.gens + 1, assigns: Map.delete(s.assigns, id)}

        maybe_recycle(
          reply(s, id, fn ->
            case File.read(path) do
              {:ok, wav} ->
                File.rm(path)
                Logger.debug("qwen-tts: #{r["dur"]}s in #{r["ms"]}ms")
                {:ok, wav}

              _ ->
                {:error, :wav_missing}
            end
          end)
        )

      {:ok, %{"id" => id, "error" => err}} ->
        reply(%{s | assigns: Map.delete(s.assigns, id)}, id, fn -> {:error, err} end)

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
