defmodule Autopoet.QwenTts do
  @moduledoc """
  Cloud stub. The Qwen3-TTS sidecar is a DESKTOP feature (local MLX synthesis
  on Apple silicon) — the headless cloud brain has no speakers and no Metal.
  Every call reports off/unavailable; callers fall back to Kokoro/server TTS.
  """
  def start_link(_), do: :ignore
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  def status, do: "off"
  def ready?, do: false
  def ensure(_model \\ :custom), do: :ok
  def switch(_model), do: :ok
  def model, do: nil
  def speak(_text, _voice \\ nil, _instruct \\ nil), do: {:error, :not_available}
  def clone(_text, _ref, _ref_text), do: {:error, :not_available}
end
