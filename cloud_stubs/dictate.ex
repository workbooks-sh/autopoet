defmodule Autopoet.Dictate do
  @moduledoc """
  Cloud stub. Dictation / STT (Whisper via Bumblebee/EXLA) is a DESKTOP feature — the headless cloud
  brain ships without the ML stack. The real module lives in `desktop_ml/dictate.ex`. Same public API,
  so the control surface compiles and degrades gracefully.
  """
  def transcribe(_audio, _ext), do: {:error, :not_available_on_cloud}
  def partial(_audio), do: {:error, :not_available_on_cloud}
end
