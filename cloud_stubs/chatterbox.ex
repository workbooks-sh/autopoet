defmodule Autopoet.Chatterbox do
  @moduledoc "Cloud stub — the quality voice engine is a desktop feature."
  def ready?, do: false
  def status, do: "off"
  def speak(_text), do: {:error, :not_available_on_cloud}
end
