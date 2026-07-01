defmodule Autopoet.Capture do
  @moduledoc """
  Always-on bus recorder — the replay corpus generator. Subscribes to the real
  `Nexus.Events` bus and appends every delivered event as a framed term
  (`<<size::32, term_to_binary(event)>>`) to `data/traces/<utc-date>.etfs` — the
  exact format validated in the chamber (crash-tolerant: a torn tail frame is
  skipped on read; `gym/replay.exs` consumes these files unchanged).
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "traces"])
  def count, do: GenServer.call(__MODULE__, :count)

  @impl true
  def init(nil) do
    File.mkdir_p!(dir())
    Nexus.Events.subscribe()
    {:ok, %{io: nil, day: nil, n: 0}}
  end

  @impl true
  def handle_info({:event, ev}, s) do
    s = ensure_io(s)
    blob = :erlang.term_to_binary(ev)
    :ok = :file.write(s.io, <<byte_size(blob)::32, blob::binary>>)
    {:noreply, %{s | n: s.n + 1}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_call(:count, _from, s), do: {:reply, s.n, s}

  # Daily rotation by filename, switched lazily at write time.
  defp ensure_io(%{day: day} = s) do
    today = Date.to_iso8601(Date.utc_today())

    if day == today do
      s
    else
      if s.io, do: File.close(s.io)
      {:ok, io} = File.open(Path.join(dir(), today <> ".etfs"), [:append, :binary, :raw])
      %{s | io: io, day: today}
    end
  end
end
