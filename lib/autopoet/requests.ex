defmodule Autopoet.Requests do
  @moduledoc """
  The ONE intake for typed self-edit requests — the issue system. Two filers,
  one lane:

    * humans, via `./autopoetctl request <target> <change>`
    * ANY agent/limb, via the ungated `request` bash verb inside its run
      (metacognition is deliberately grant-free in the runtime)

  Both paths produce a `Nexus.Autopoet.Request` → a `self_edit.requested` bus
  event; this process subscribes and queues every one (deduped by the request's
  own key) until the next heartbeat drains them into the brain. Fire-and-forget:
  a filer never waits.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def file(target, change) do
    with {:ok, req} <- Nexus.Autopoet.Request.new(%{target: target, change: change}) do
      Nexus.Autopoet.Request.file(req)
      Autopoet.Log.puts("request filed: #{target} — #{change}")
      :ok
    end
  end

  def pending, do: GenServer.call(__MODULE__, :pending)

  @doc "Hand all pending requests to the cycle and clear the queue."
  def drain, do: GenServer.call(__MODULE__, :drain)

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "requests"])

  @impl true
  def init(nil) do
    File.mkdir_p!(dir())

    # Reload undrained requests from disk — a restart must not eat a filed issue.
    q =
      for f <- Path.wildcard(Path.join(dir(), "*.req")), into: %{} do
        {Path.basename(f, ".req"), f |> File.read!() |> :erlang.binary_to_term()}
      end

    if map_size(q) > 0, do: Autopoet.Log.puts("requests: #{map_size(q)} pending reloaded from disk")

    Nexus.Events.subscribe()
    {:ok, q}
  end

  @impl true
  def handle_info({:event, %{kind: "self_edit.requested"} = ev}, q) do
    # ONE pending request per TARGET — the latest wins. Rapid vault saves collapse
    # to the newest content; repeated limb failures collapse to the latest reason.
    # Distinct intents belong on distinct targets.
    key = fname(to_string(ev[:target]))
    entry = %{target: ev[:target], change: ev[:change], why: ev[:why], evidence: ev[:evidence]}
    File.write!(Path.join(dir(), key <> ".req"), :erlang.term_to_binary(entry))
    Autopoet.Log.puts("request queued (#{ev[:target]}): #{String.slice(to_string(ev[:change]), 0, 120)}")
    {:noreply, Map.put(q, key, entry)}
  end

  def handle_info(_msg, q), do: {:noreply, q}

  @impl true
  def handle_call(:pending, _from, q), do: {:reply, Map.values(q), q}

  def handle_call(:drain, _from, q) do
    for key <- Map.keys(q), do: File.rm(Path.join(dir(), key <> ".req"))
    {:reply, Map.values(q), %{}}
  end

  # dedup keys become filenames — encode so slashes/spaces can't escape the dir
  defp fname(key), do: Base.url_encode64(:erlang.md5(to_string(key)), padding: false)
end
