defmodule Autopoet.Voice do
  @moduledoc """
  The autopoet's voice — v1 is fully LOCAL: a serialized speech queue over macOS
  `say` (no cloud, no keys). The UI polls `status/0` to flap the mouth in time
  with actual speech. Utterances queue rather than overlap; `stop/0` silences
  everything. The mic side (Moonshine local STT or Gemini Live realtime) plugs
  in later without changing this seam.
  """
  use GenServer

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
    System.cmd("pkill", ["-x", "say"], stderr_to_stdout: true)
    :ok
  end

  @doc "`:speaking` while an utterance plays (or is queued), else `:idle`."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(:ok), do: {:ok, %{queue: :queue.new(), task: nil}}

  @impl true
  def handle_cast({:speak, text}, state) do
    state = %{state | queue: :queue.in(text, state.queue)}
    {:noreply, maybe_start(state)}
  end

  def handle_cast(:stop, state) do
    {:noreply, %{state | queue: :queue.new()}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    speaking = state.task != nil or not :queue.is_empty(state.queue)
    {:reply, if(speaking, do: :speaking, else: :idle), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{task: pid} = state) do
    {:noreply, maybe_start(%{state | task: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_start(%{task: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, text}, rest} ->
        {pid, _ref} = spawn_monitor(fn -> System.cmd("say", ["-r", "190", text], stderr_to_stdout: true) end)
        %{state | queue: rest, task: pid}

      {:empty, _} ->
        state
    end
  end

  defp maybe_start(state), do: state
end
