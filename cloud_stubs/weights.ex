defmodule Autopoet.Weights do
  @moduledoc """
  Cloud stub. First-run ML weight download is a DESKTOP feature (the cloud brain
  ships no local voice engines). The real module lives in `desktop_ml/weights.ex`.
  Same public API; `start_link/1` ignores so the Spine child slot is a no-op.
  """
  def start_link(_), do: :ignore
  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  def status, do: "unavailable — weights are a desktop feature (cloud brain is headless)"
  def complete?, do: false
end
