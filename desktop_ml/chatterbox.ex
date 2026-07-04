defmodule Autopoet.Chatterbox do
  @moduledoc """
  Chatterbox-Turbo TTS — the QUALITY voice engine, run from the official ONNX
  export through a persistent python port (torch-free venv: onnxruntime +
  tokenizers only). Slower than Kokoro (~4-6s/sentence vs 2.4s on this
  machine; the 350M LM is autoregressive) but with natural prosody,
  paralinguistic tags ([chuckle], [cough], …), and a voice cloned from any
  ~10s reference clip (data/models/chatterbox/ref-voice.wav; conditioning is
  computed once and cached as conds.npz).

  Engine files under data/models/chatterbox/, venv under
  data/venvs/chatterbox/. Protocol: "SPEAK <b64 text>" in, "WAV <b64 wav>"
  out, one in flight at a time (callers queue). Selected per-request via
  /voice/tts?engine=chatterbox or app-wide with AUTOPOET_TTS=chatterbox.
  """
  use GenServer

  @line_max 8_000_000

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def ready? do
    GenServer.call(__MODULE__, :ready?, 1_000)
  catch
    :exit, _ -> false
  end

  def status do
    cond do
      ready?() -> "ready"
      installed?() -> "loading"
      true -> "off"
    end
  end

  @doc """
  Synthesize → {:ok, wav_binary} | {:error, reason}. Queues behind in-flight
  work. Sampler knobs (all optional, HF-demo defaults):
  temp 0.8 · top_p 0.95 · top_k 1000 · rep 1.2 · min_p 0
  """
  def speak(text, knobs \\ %{}) do
    GenServer.call(__MODULE__, {:speak, text, knobs}, 90_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  defp root, do: File.cwd!()
  defp python, do: Path.join(root(), "data/venvs/chatterbox/bin/python")
  defp script, do: Path.join(root(), "priv/chatterbox_port.py")
  defp models, do: Path.join(root(), "data/models/chatterbox")

  defp installed? do
    File.exists?(python()) and File.exists?(script()) and
      File.exists?(Path.join(models(), "onnx/language_model_q4.onnx"))
  end

  @impl true
  def init(:ok) do
    if installed?() do
      port =
        Port.open({:spawn_executable, python()}, [
          {:args, [script()]},
          {:line, @line_max},
          :binary,
          :exit_status,
          {:cd, root()}
        ])

      {:ok, %{port: port, ready: false, queue: :queue.new(), acc: ""}}
    else
      {:ok, :off}
    end
  end

  @impl true
  def handle_call(:ready?, _from, %{ready: r} = state), do: {:reply, r, state}
  def handle_call(:ready?, _from, state), do: {:reply, false, state}

  def handle_call({:speak, _, _}, _from, :off), do: {:reply, {:error, :not_installed}, :off}

  def handle_call({:speak, _, _}, _from, %{ready: false} = s),
    do: {:reply, {:error, :not_ready}, s}

  def handle_call({:speak, text, knobs}, from, state) do
    suffix =
      knobs
      |> Map.take(["t", "p", "k", "r", "m", "s"])
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    Port.command(state.port, String.trim("SPEAK #{Base.encode64(text)} #{suffix}") <> "\n")
    {:noreply, %{state | queue: :queue.in(from, state.queue)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | acc: state.acc <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    {:noreply, route_line(state.acc <> chunk, %{state | acc: ""})}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Autopoet.Log.puts("chatterbox: port exited (#{code})")
    for from <- :queue.to_list(state.queue), do: GenServer.reply(from, {:error, :port_died})
    {:noreply, :off}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp route_line("READY", state) do
    Autopoet.Log.puts("chatterbox: quality voice engine up (ONNX turbo, port)")
    %{state | ready: true}
  end

  defp route_line("WAV " <> b64, state), do: reply_next(state, Base.decode64(b64))
  defp route_line("ERR " <> msg, state), do: reply_next(state, {:error, String.slice(msg, 0, 160)})
  defp route_line(_, state), do: state

  defp reply_next(state, result) do
    case :queue.out(state.queue) do
      {{:value, from}, rest} ->
        GenServer.reply(
          from,
          case result do
            {:ok, wav} -> {:ok, wav}
            :error -> {:error, :bad_wav}
            {:error, _} = e -> e
          end
        )

        %{state | queue: rest}

      {:empty, _} ->
        state
    end
  end
end
