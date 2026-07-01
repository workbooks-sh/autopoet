defmodule Autopoet.Requests do
  @moduledoc """
  Pending typed self-edit requests — the way a human hands the autopoet work
  (`./autopoetctl request <target> <change...>`). Filed through the real
  `Nexus.Autopoet.Request` (typed delta = the injection firewall; emits
  `self_edit.requested` onto the bus), held here until the next heartbeat cycle
  drains them. Deduped by the request's own dedup key.
  """
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def file(target, change) do
    with {:ok, req} <- Nexus.Autopoet.Request.new(%{target: target, change: change}) do
      Nexus.Autopoet.Request.file(req)

      Agent.update(
        __MODULE__,
        &Map.put(&1, Nexus.Autopoet.Request.dedup_key(req), %{target: target, change: change})
      )

      Autopoet.Log.puts("request filed: #{target} — #{change}")
      :ok
    end
  end

  def pending, do: Agent.get(__MODULE__, &Map.values/1)

  @doc "Hand all pending requests to the cycle and clear the queue."
  def drain, do: Agent.get_and_update(__MODULE__, fn m -> {Map.values(m), %{}} end)
end
