defmodule Autopoet.Kokoro do
  @moduledoc """
  Cloud stub. Kokoro TTS is a DESKTOP feature (local neural voice synthesis) — the headless cloud brain
  ships without it. The real module lives in `desktop_ml/kokoro.ex`. Same public API so the control
  surface compiles and degrades gracefully.
  """
  def status, do: "unavailable — TTS is a desktop feature (cloud brain is headless)"
  def speak(_text, _voice \\ nil), do: {:error, :not_available_on_cloud}
end
