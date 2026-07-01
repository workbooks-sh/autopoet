defmodule Autopoet.Snapshot do
  @moduledoc """
  Persists the otherwise in-memory `Nexus.Telemetry` ledger: every 60s, if the
  ledger changed, a framed snapshot `%{at, ledger}` is appended to
  `data/traces/telemetry.etfs`. Reboot-safe history for the feedback substrate —
  same framed format as the traces.
  """
  use GenServer

  @tick 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def path, do: Path.join([Autopoet.Discovery.home(), "data", "traces", "telemetry.etfs"])

  @impl true
  def init(nil) do
    File.mkdir_p!(Path.dirname(path()))
    :timer.send_interval(@tick, :tick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, last) do
    ledger = Nexus.Telemetry.ledger()

    if ledger != %{} and ledger != last do
      frame = :erlang.term_to_binary(%{at: System.os_time(:second), ledger: ledger})
      File.write!(path(), <<byte_size(frame)::32, frame::binary>>, [:append])
      {:noreply, ledger}
    else
      {:noreply, last}
    end
  end
end
