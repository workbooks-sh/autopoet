defmodule Autopoet.Window do
  @moduledoc """
  The containment window: one native macOS frame (OTP `:wx`, no webview, no extra
  deps), white background, the debug log in a read-only text control filling the
  client area (a wxFrame auto-fills its single child). Closing it — the stoplight —
  runs `handle_info({:wx, …, :close_window})`, which HALTS THE ENTIRE BEAM. The
  `close/0` API drives the exact same handler so the kill path is testable from the
  control API.

  restart: :temporary — if the window dies we are already halting; the supervisor
  must not resurrect it mid-shutdown.
  """
  use GenServer, restart: :temporary
  import Bitwise

  # wx.hrl macros aren't importable from Elixir — the two styles we need:
  @wx_te_multiline 0x0020
  @wx_te_readonly 0x0010

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Programmatic close — same wx close event the stoplight produces."
  def close, do: GenServer.cast(__MODULE__, :close)

  @impl true
  def init(nil) do
    :wx.new()
    frame = :wxFrame.new(:wx.null(), -1, ~c"autopoet", size: {760, 500})
    :wxWindow.setBackgroundColour(frame, {255, 255, 255, 255})

    text = :wxTextCtrl.new(frame, -1, style: @wx_te_multiline ||| @wx_te_readonly)
    :wxWindow.setBackgroundColour(text, {255, 255, 255, 255})

    :wxFrame.connect(frame, :close_window)
    :wxFrame.show(frame)

    Autopoet.Log.subscribe()
    for line <- Autopoet.Log.recent(100), do: append(text, line)

    {:ok, %{frame: frame, text: text}}
  end

  @impl true
  def handle_info({:autopoet_log, line}, s) do
    append(s.text, line)
    {:noreply, s}
  end

  def handle_info({:wx, _id, _obj, _user, {:wxClose, :close_window}}, s) do
    Autopoet.Log.puts("window closed — halting BEAM (kill switch)")
    :wxFrame.destroy(s.frame)
    :init.stop()
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_cast(:close, s) do
    :wxFrame.close(s.frame)
    {:noreply, s}
  end

  defp append(text, line), do: :wxTextCtrl.appendText(text, ~c"#{line}\n")
end
