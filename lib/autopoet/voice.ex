defmodule Autopoet.Voice do
  @moduledoc """
  The autopoet's voice — fully LOCAL, with REAL lip sync:

    1. `say -o` renders the utterance to AIFF (fast, no audio yet)
    2. the PCM is parsed right here (chunk walk, s16be) into an amplitude
       envelope — RMS per 50ms window, normalized 0..1
    3. `afplay` plays the file while `/voice/sync.json` serves the envelope +
       elapsed time, so the UI opens the mouth exactly with the loudness:
       pauses sit flat, syllables open, silence closes.

  Utterances queue (never overlap); `stop/0` silences and clears. The mic side
  (Moonshine local STT or Gemini Live realtime) plugs in later at this seam.
  """
  use GenServer

  @window_ms 50

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def speak(text) when is_binary(text) do
    clean =
      text
      |> String.replace(~r/[^\p{L}\p{N}\s.,;:!?'"()\[\]-]/u, " ")
      |> String.slice(0, 1200)
      |> String.trim()

    if clean != "", do: GenServer.cast(__MODULE__, {:speak, clean})
    :ok
  end

  def stop do
    GenServer.cast(__MODULE__, :stop)
    System.cmd("pkill", ["-x", "afplay"], stderr_to_stdout: true)
    :ok
  end

  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Everything the UI needs to sync the mouth: status, elapsed, envelope."
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(:ok), do: {:ok, %{queue: :queue.new(), task: nil, envelope: [], started: 0, utter: 0}}

  @impl true
  def handle_cast({:speak, text}, state) do
    {:noreply, maybe_start(%{state | queue: :queue.in(text, state.queue)})}
  end

  def handle_cast(:stop, state) do
    {:noreply, %{state | queue: :queue.new()}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    speaking = state.task != nil or not :queue.is_empty(state.queue)
    {:reply, if(speaking, do: :speaking, else: :idle), state}
  end

  def handle_call(:sync, _from, state) do
    reply =
      if state.task do
        %{
          status: "speaking",
          utter: state.utter,
          elapsed_ms: System.monotonic_time(:millisecond) - state.started,
          window_ms: @window_ms,
          envelope: state.envelope
        }
      else
        %{status: "idle", utter: state.utter, elapsed_ms: 0, window_ms: @window_ms, envelope: []}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{task: pid} = state) do
    {:noreply, maybe_start(%{state | task: nil, envelope: []})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_start(%{task: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, text}, rest} ->
        aiff = Path.join(System.tmp_dir!(), "ap-voice-#{:erlang.unique_integer([:positive])}.aiff")
        System.cmd("say", ["-r", "190", "-o", aiff, text], stderr_to_stdout: true)
        env = envelope(aiff)
        {pid, _ref} =
          spawn_monitor(fn ->
            System.cmd("afplay", [aiff], stderr_to_stdout: true)
            File.rm(aiff)
          end)

        %{state | queue: rest, task: pid, envelope: env,
          started: System.monotonic_time(:millisecond), utter: state.utter + 1}

      {:empty, _} ->
        state
    end
  end

  defp maybe_start(state), do: state

  # ── AIFF → amplitude envelope (RMS per window, normalized 0..1) ───────────

  defp envelope(aiff) do
    # `say` emits AIFF-C ("AIFC", compression "twos" = plain s16be) — same PCM
    with {:ok, <<"FORM", _size::32, form::binary-4, chunks::binary>>} when form in ["AIFF", "AIFC"] <-
           File.read(aiff),
         %{rate: rate, channels: ch, samples: samples} <- walk(chunks, %{}) do
      per_window = max(1, trunc(rate * @window_ms / 1000) * ch)

      rms =
        for <<window::binary-size(per_window * 2) <- samples>> do
          n = byte_size(window) |> div(2)
          sum = for(<<s::signed-16 <- window>>, reduce: 0.0, do: (acc -> acc + s * s))
          :math.sqrt(sum / n)
        end

      peak = Enum.max([1.0 | rms])
      Enum.map(rms, &Float.round(min(1.0, &1 / peak), 2))
    else
      _ -> []
    end
  end

  defp walk(<<>>, acc), do: acc

  defp walk(<<id::binary-4, size::32, rest::binary>>, acc) do
    padded = size + rem(size, 2)

    case rest do
      <<body::binary-size(padded), tail::binary>> ->
        acc =
          case id do
            "COMM" ->
              <<channels::16, _frames::32, _bits::16, exp::signed-16, mant::64, _::binary>> = body
              rate = mant * :math.pow(2, exp - 16_383 - 63)
              Map.merge(acc, %{rate: trunc(rate), channels: channels})

            "SSND" ->
              <<_offset::32, _block::32, samples::binary>> = body
              Map.put(acc, :samples, samples)

            _ ->
              acc
          end

        walk(tail, acc)

      _ ->
        acc
    end
  end
end
