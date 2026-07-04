defmodule Autopoet.Affect do
  @moduledoc "Cloud stub — emotion understanding is a desktop feature."
  def ready?, do: false
  def classify(_text, _k \\ 5), do: {:error, :not_available_on_cloud}
end
