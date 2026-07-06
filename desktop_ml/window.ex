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

  # WKWebView swallows every mouse event inside it — `-webkit-app-region:drag` in
  # the page's CSS has NO effect there (that hookup is a Chromium/Electron thing;
  # WKWebView has no native equivalent, confirmed against real-world WKWebView
  # custom-chrome writeups). So dragging can't be a CSS/HTML affair at all in
  # frameless mode: it's this thin NATIVE wx panel instead, layered on top of the
  # webview across the very top of the frame, driven by plain mouse-capture +
  # Move() — the standard wxWidgets frameless-window-drag recipe. Sized to 7px so
  # it tucks under the real controls that start a few px down (#toprow at 7px,
  # #canvasbar at 12px in app.html) without covering any of them.
  @drag_strip_height 7

  def frameless?, do: System.get_env("AUTOPOET_FRAMELESS") in ~w(1 true)

  @impl true
  def init(nil) do
    :wx.new()
    style = if frameless?(), do: @wx_resize_border, else: @wx_default_frame_style
    frame = :wxFrame.new(:wx.null(), -1, ~c"autopoet", size: {1440, 900}, style: style)
    :wxWindow.setBackgroundColour(frame, {251, 251, 249, 255})

    view = attach_view(frame)
    drag = if frameless?(), do: attach_drag_strip(frame)

    # A frame with exactly one child auto-fills it with no sizer needed — that's
    # what attach_view relied on. The drag strip is a SECOND child, which forfeits
    # that implicit behavior (confirmed empirically: the webview silently
    # collapsed to ~0 size, rendering a blank window). So once there's a drag
    # strip, the content view's geometry has to be driven explicitly.
    if drag, do: resize_content(frame, view)

    :wxFrame.connect(frame, :close_window)
    if drag, do: :wxFrame.connect(frame, :size)
    :wxTopLevelWindow.maximize(frame)
    :wxFrame.show(frame)

    {:ok, %{frame: frame, view: view, drag: drag, drag_offset: nil}}
  end

  defp resize_content(frame, view) do
    {w, h} = :wxWindow.getClientSize(frame)
    content = elem(view, 1)
    :wxWindow.setSize(content, {0, 0, w, h})
  end

  @doc "Window control from the page's custom chrome (frameless mode)."
  def control(:close), do: close()
  def control(:minimize), do: GenServer.cast(__MODULE__, :minimize)
  def control(:maximize), do: GenServer.cast(__MODULE__, :maximize)
  def control(_), do: :ok

  @doc "Match the native chrome (frame + drag strip) to the page's light/dark theme."
  def set_theme(theme) when theme in [:light, :dark], do: GenServer.cast(__MODULE__, {:set_theme, theme})
  def set_theme(_), do: :ok

  # The app UI: a native WKWebView filling the frame (single child auto-fills).
  defp attach_view(frame) do
    # Pass ?frameless=1 so the page draws its own traffic-light chrome (this frame has
    # no native title bar in frameless mode). A plain browser tab hitting localhost has
    # no flag → no fake stoplights. Replaces the old serve-time __CHROME__ substitution.
    q = if frameless?(), do: "?frameless=1", else: ""
    url = ~c"http://127.0.0.1:#{Autopoet.Application.port()}/#{q}"
    wv = :wxWebView.new(frame, -1, url: url)
    # right-click → Inspect Element in the desktop window: enable the context menu
    # (WKWebView also needs `defaults write -g WebKitDeveloperExtras -bool true`).
    try do :wxWebView.enableContextMenu(wv, true) rescue _ -> :ok catch _, _ -> :ok end
    {:webview, wv}
  rescue
    _ ->
      Autopoet.Log.puts("window: wxWebView unavailable — degrading to text log")
      text = :wxTextCtrl.new(frame, -1, style: @wx_te_multiline ||| @wx_te_readonly)
      :wxWindow.setBackgroundColour(text, {255, 255, 255, 255})
      Autopoet.Log.subscribe()
      for line <- Autopoet.Log.recent(100), do: :wxTextCtrl.appendText(text, ~c"#{line}\n")
      {:text, text}
  end

  # The real drag surface (see @drag_strip_height) — a bare wx panel, no sizer,
  # manually kept in sync with the frame's width on resize (handle_info for the
  # frame's :size event, below).
  defp attach_drag_strip(frame) do
    {w, _h} = :wxWindow.getSize(frame)
    panel = :wxPanel.new(frame, pos: {0, 0}, size: {w, @drag_strip_height})
    :wxWindow.setBackgroundColour(panel, {251, 251, 249, 255})
    :wxWindow.connect(panel, :left_down)
    :wxWindow.connect(panel, :left_up)
    :wxWindow.connect(panel, :motion)
    :wxWindow.connect(panel, :mouse_capture_lost)
    panel
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

  # Frameless-drag: left_down on the drag strip remembers the click's position
  # relative to the strip; every motion event while the button is down re-derives
  # the frame's screen position from that fixed offset and the mouse's CURRENT
  # screen position, and moves the frame there directly. `%{drag: obj}` on the
  # state pattern scopes this to events from OUR panel only.
  def handle_info(
        {:wx, _id, obj, _user, {:wxMouse, :left_down, x, y, _, _, _, _, _, _, _, _, _, _}},
        %{drag: obj} = s
      ) do
    :wxWindow.captureMouse(obj)
    {:noreply, %{s | drag_offset: {x, y}}}
  end

  def handle_info(
        {:wx, _id, obj, _user, {:wxMouse, :motion, x, y, true, _, _, _, _, _, _, _, _, _}},
        %{drag: obj, drag_offset: {ox, oy}} = s
      ) do
    {sx, sy} = :wxWindow.clientToScreen(obj, {x, y})
    :wxWindow.move(s.frame, {sx - ox, sy - oy})
    {:noreply, s}
  end

  def handle_info(
        {:wx, _id, obj, _user, {:wxMouse, :left_up, _x, _y, _, _, _, _, _, _, _, _, _, _}},
        %{drag: obj} = s
      ) do
    if s.drag_offset, do: :wxWindow.releaseMouse(obj)
    {:noreply, %{s | drag_offset: nil}}
  end

  def handle_info({:wx, _id, obj, _user, {:wxMouseCaptureLost, :mouse_capture_lost}}, %{drag: obj} = s) do
    {:noreply, %{s | drag_offset: nil}}
  end

  # Keep the drag strip spanning the full width, and the content view filling
  # the rest, across every resize (see resize_content/2 above for why the
  # content view needs this explicitly once it's no longer the frame's only
  # child).
  def handle_info({:wx, _id, obj, _user, {:wxSize, :size, {w, _h}, _rect}}, %{frame: obj, drag: drag} = s)
      when not is_nil(drag) do
    :wxWindow.setSize(drag, {w, @drag_strip_height})
    resize_content(s.frame, s.view)
    {:noreply, s}
  end

  # Best-effort bring the window forward — used after an out-of-app flow returns
  # (the cloud sign-in device flow completes in the SYSTEM browser; on the callback
  # we raise the window and bounce the dock so the user knows to switch back). macOS
  # won't let a background app steal focus outright, so requestUserAttention (the
  # dock bounce) is the honest signal alongside raise().
  def handle_info(:to_front, s) do
    :wxWindow.raise(s.frame)
    try do :wxTopLevelWindow.requestUserAttention(s.frame) rescue _ -> :ok catch _, _ -> :ok end
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_cast(:close, s) do
    :wxFrame.close(s.frame)
    {:noreply, s}
  end

  def handle_cast(:minimize, s) do
    # wx's Erlang binding takes an OPTIONS keyword list, not a bare boolean —
    # iconize(frame, true) doesn't exist and raises FunctionClauseError.
    #
    # NOTE ON A MACOS PLATFORM CEILING: on macOS, -[NSWindow miniaturize:] (what
    # this ultimately calls) is a documented no-op for a window without a title
    # bar. Our frame is deliberately CAPTION-less (@wx_resize_border only) so the
    # page can draw its own chrome instead of the native one — that's the whole
    # point of frameless mode. Adding wxMINIMIZE_BOX to the frame style DOES make
    # the OS honor iconize(), but wxWidgets' Cocoa port brings back the full
    # native title bar (with its own real traffic lights) the instant any of
    # CLOSE_BOX/MINIMIZE_BOX/MAXIMIZE_BOX/SYSTEM_MENU is set — verified empirically,
    # it renders a second, native stoplight stacked above the custom HTML one.
    # There is no portable wx knob for "titled + miniaturizable but visually
    # bare" (that needs direct NSWindow access — titlebarAppearsTransparent +
    # titleVisibility, outside wx/Erlang without native code). So in frameless
    # mode this call is correct-and-harmless rather than a true dock-genie: it
    # won't crash, and it's a no-op at the OS level. maximize/close are real.
    :wxTopLevelWindow.iconize(s.frame, iconize: true)
    {:noreply, s}
  end

  def handle_cast(:maximize, s) do
    # Same shape here: maximize/2 wants [{maximize, bool}], not a raw bool — the
    # old bare-boolean call crashed this GenServer (restart: :temporary, so it
    # never came back and the wx frame died with it, taking the window with it).
    :wxTopLevelWindow.maximize(s.frame, maximize: not :wxTopLevelWindow.isMaximized(s.frame))
    {:noreply, s}
  end

  # Repaint the native chrome to match the page theme. The webview draws its own
  # dark UI, but the frame + drag strip are wx surfaces (hardcoded paper at boot);
  # without this they stay light and leak a white seam at the top in dark mode.
  def handle_cast({:set_theme, theme}, s) do
    color = if theme == :dark, do: {16, 19, 24, 255}, else: {251, 251, 249, 255}
    for win <- [s.frame, s.drag], win != nil do
      :wxWindow.setBackgroundColour(win, color)
      :wxWindow.refresh(win)
    end
    {:noreply, s}
  end
end
