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

  @impl true
  def init(nil) do
    Nexus.Events.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %{kind: "self_edit.requested"} = ev}, q) do
    key = ev[:dedup_key] || "#{ev[:target]}::#{ev[:change]}"
    Autopoet.Log.puts("request queued (#{ev[:target]}): #{String.slice(to_string(ev[:change]), 0, 120)}")
    {:noreply, Map.put(q, key, %{target: ev[:target], change: ev[:change], why: ev[:why], evidence: ev[:evidence]})}
  end

  def handle_info(_msg, q), do: {:noreply, q}

  @impl true
  def handle_call(:pending, _from, q), do: {:reply, Map.values(q), q}
  def handle_call(:drain, _from, q), do: {:reply, Map.values(q), %{}}
end
