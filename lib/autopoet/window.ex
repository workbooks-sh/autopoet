defmodule Autopoet.Window do
  @moduledoc """
  The containment window, v2: one native macOS frame hosting a native WebView
  (OTP `:wx` + wxWebView → WKWebView) pointed at the local control page — the
  force world-graph IS the app. Opens maximized; the title bar carries no text
  (stoplight + drag + double-click-zoom stay native). Closing the window — the
  stoplight — HALTS THE ENTIRE BEAM: the autopoet cannot outlive its window.

  If this OTP's wx lacks WebView, the window degrades to the v1 text log —
  containment never depends on the pretty path.

  restart: :temporary — if the window dies we are already halting.
  """
  use GenServer, restart: :temporary
  import Bitwise

  @wx_te_multiline 0x0020
  @wx_te_readonly 0x0010

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Programmatic close — same wx close event the stoplight produces."
  def close, do: GenServer.cast(__MODULE__, :close)

  # wxRESIZE_BORDER only — no wxCAPTION, so macOS draws NO native title bar and NO
  # native traffic lights; the page draws its own (custom chrome, the elixir-desktop
  # pattern). Default frame otherwise.
  @wx_resize_border 0x0040
  @wx_default_frame_style 0x0009_09FF

  def frameless?, do: System.get_env("AUTOPOET_FRAMELESS") in ~w(1 true)

  @impl true
  def init(nil) do
    :wx.new()
    style = if frameless?(), do: @wx_resize_border, else: @wx_default_frame_style
    frame = :wxFrame.new(:wx.null(), -1, ~c"autopoet", size: {1440, 900}, style: style)
    :wxWindow.setBackgroundColour(frame, {251, 251, 249, 255})

    view = attach_view(frame)

    :wxFrame.connect(frame, :close_window)
    :wxTopLevelWindow.maximize(frame)
    :wxFrame.show(frame)

    {:ok, %{frame: frame, view: view}}
  end

  @doc "Window control from the page's custom chrome (frameless mode)."
  def control(:close), do: close()
  def control(:minimize), do: GenServer.cast(__MODULE__, :minimize)
  def control(:maximize), do: GenServer.cast(__MODULE__, :maximize)
  def control(_), do: :ok

  # The app UI: a native WKWebView filling the frame (single child auto-fills).
  defp attach_view(frame) do
    url = ~c"http://127.0.0.1:#{Autopoet.Application.port()}/"
    {:webview, :wxWebView.new(frame, -1, url: url)}
  rescue
    _ ->
      Autopoet.Log.puts("window: wxWebView unavailable — degrading to text log")
      text = :wxTextCtrl.new(frame, -1, style: @wx_te_multiline ||| @wx_te_readonly)
      :wxWindow.setBackgroundColour(text, {255, 255, 255, 255})
      Autopoet.Log.subscribe()
      for line <- Autopoet.Log.recent(100), do: :wxTextCtrl.appendText(text, ~c"#{line}\n")
      {:text, text}
  end

  @impl true
  def handle_info({:autopoet_log, line}, %{view: {:text, text}} = s) do
    :wxTextCtrl.appendText(text, ~c"#{line}\n")
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

  def handle_cast(:minimize, s) do
    :wxTopLevelWindow.iconize(s.frame)
    {:noreply, s}
  end

  def handle_cast(:maximize, s) do
    :wxTopLevelWindow.maximize(s.frame, not :wxTopLevelWindow.isMaximized(s.frame))
    {:noreply, s}
  end
end
