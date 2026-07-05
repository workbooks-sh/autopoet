defmodule Autopoet.Desks do
  @moduledoc """
  Desk supervision for the project spine — one DynamicSupervisor + Registry;
  each project's desk is a supervised child keyed by slug. Replaces the
  AUTOPOET_DESK/AUTOPOET_VENTURE env-gated singletons and the second-BEAM
  venture-home hack: many desks, one organism.

  Desks do NOT auto-start at boot (same posture as the heartbeat: running is
  an explicit act) — `launch/1` starts a project's desk, `halt/1` stops it.
  """

  def child_spec(_), do: %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_link, []}}

  def start_link do
    children = [
      {Registry, keys: :unique, name: Autopoet.DeskRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Autopoet.DeskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @doc "Start the desk for `slug` (must be a created project). Idempotent."
  def launch(slug) do
    case Autopoet.Projects.get(slug) do
      nil ->
        {:error, :unknown_project}

      %{status: :archived} ->
        {:error, :archived}

      project ->
        spec = {Autopoet.Venture, project}

        case DynamicSupervisor.start_child(Autopoet.DeskSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "Stop the desk for `slug` (no-op if not running)."
  def halt(slug) do
    case whereis(slug) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Autopoet.DeskSupervisor, pid)
    end
  end

  def running?(slug), do: whereis(slug) != nil

  def whereis(slug) do
    case Registry.lookup(Autopoet.DeskRegistry, to_string(slug)) do
      [{pid, _}] -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Slugs of every running desk."
  def running do
    Registry.select(Autopoet.DeskRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end
end
