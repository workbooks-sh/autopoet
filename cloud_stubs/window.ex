defmodule Autopoet.Window do
  @moduledoc """
  Cloud stub. The native window (wxWidgets / :wx) is a DESKTOP feature — the headless cloud brain has no
  GUI. The real module lives in `desktop_ml/window.ex`. Same public API so the control surface compiles;
  the window is never started on cloud (`Autopoet.Application` gates it on `headless?`).
  """
  def frameless?, do: false
  def close, do: :ok
  def control(_action), do: :ok
end
