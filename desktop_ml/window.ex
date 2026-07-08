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

  # The frame must be a normal titled window so macOS makes it miniaturizable, zoomable,
  # AND fullscreen-capable. CRITICAL: pass the REAL wxDEFAULT_FRAME_STYLE — a previous
  # hand-rolled constant (0x0009_09FF) accidentally carried wxFRAME_TOOL_WINDOW (0x4),
  # which makes wxOSX create the frame as a UTILITY NSPanel: no native fullscreen ever,
  # collectionBehavior writes silently rejected, invisible to accessibility. That one bit
  # was the root of every "mac window acts wrong" symptom. In frameless mode the native
  # shim (Autopoet.Window.Mac) restyles the titled window INSET afterward: transparent
  # titlebar, hidden title, full-size content, native traffic lights hidden — the page's
  # stoplights are the visible controls but real window actions still fire.
  # wxDEFAULT_FRAME_STYLE = CAPTION|CLIP_CHILDREN|CLOSE_BOX|SYSTEM_MENU|MINIMIZE_BOX|
  #                         MAXIMIZE_BOX|RESIZE_BORDER (wx 3.2)
  @wx_default_frame_style 0x2040_1E40

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

    # INSET mode = the pretty frameless look WITH working native controls, available only
    # when the native shim loaded. Frameless requested but shim missing → a plain native
    # title bar (custom stoplights stay hidden so there's no double set of controls).
    inset? = frameless?() and Autopoet.Window.Mac.available?()

    frame = :wxFrame.new(:wx.null(), -1, ~c"autopoet", size: {1440, 900}, style: @wx_default_frame_style)
    :wxWindow.setBackgroundColour(frame, {251, 251, 249, 255})

    view = attach_view(frame, inset?)
    drag = if inset?, do: attach_drag_strip(frame)

    # A frame with exactly one child auto-fills it with no sizer needed — that's
    # what attach_view relied on. The drag strip is a SECOND child, which forfeits
    # that implicit behavior (confirmed empirically: the webview silently
    # collapsed to ~0 size, rendering a blank window). So once there's a drag
    # strip, the content view's geometry has to be driven explicitly.
    if drag, do: resize_content(frame, view)

    :wxFrame.connect(frame, :close_window)
    if drag, do: :wxFrame.connect(frame, :size)

    # Restyle to the inset (hiddenInset) look. Async on the Cocoa main thread, so it lands
    # AFTER the initial layout — schedule a :refit to grow the content into the reclaimed
    # title-bar strip (FullSizeContentView) once it applies.
    if inset? do
      Autopoet.Window.Mac.apply_inset("autopoet")
      Process.send_after(self(), :refit, 150)
    end

    # Open zoomed to fill the USABLE area (below the menu bar, beside the dock). With the
    # shim, that's Cocoa's own zoom: — it records the pre-zoom frame, so every later green
    # click toggles correctly even after the user drags/resizes (the old hand-tracked
    # setSize toggle desynced from reality on the first manual move). Sized to the restore
    # rect FIRST so zoom's un-zoom target is sane. Without the shim, plain setSize.
    area = usable_area()

    if inset? do
      :wxWindow.setSize(frame, centered_rect(area, 1280, 820))
      :wxFrame.show(frame)
      # queued on the Cocoa main thread AFTER apply_inset — order is preserved
      Autopoet.Window.Mac.zoom("autopoet")
      # Dock-click (and cmd-tab) restore a miniaturized window — wx never handles reopen
      Autopoet.Window.Mac.install_reopen("autopoet")
    else
      :wxWindow.setSize(frame, area)
      :wxFrame.show(frame)
    end

    # Let getUserMedia through the webview: WebKit's media-capture permission ask
    # lands on the webview's UIDelegate, which wx never answers → auto-deny, and the
    # system mic prompt can never fire. The shim grants at the WebKit layer (our own
    # localhost surface only); macOS TCC still owns the real device prompt.
    if Autopoet.Window.Mac.available?(), do: Autopoet.Window.Mac.allow_media("autopoet")

    {:ok, %{frame: frame, view: view, drag: drag, drag_offset: nil, maximized: true, restore_rect: centered_rect(area, 1280, 820)}}
  end

  # The primary display's usable area — {x, y, w, h} minus the menu bar and the dock.
  defp usable_area, do: :wxDisplay.getClientArea(:wxDisplay.new())

  defp centered_rect({ax, ay, aw, ah}, w, h), do: {ax + div(aw - w, 2), ay + div(ah - h, 2), w, h}

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

  @doc """
  Evaluate JavaScript inside the desktop WKWebView (loopback debug seam). The
  webview has no reachable console, so this + the page's /client/log bridge is
  how production-webview behavior is probed without guessing.
  """
  def eval_js(js) when is_binary(js), do: GenServer.cast(__MODULE__, {:eval_js, js})

  # The app UI: a native WKWebView filling the frame (single child auto-fills).
  defp attach_view(frame, inset?) do
    # Pass ?frameless=1 ONLY in inset mode, so the page draws its own stoplights over the
    # hidden native ones. With a native title bar (shim absent / non-frameless) the OS draws
    # the controls, so the custom chrome stays hidden — no double set. A plain browser tab
    # hitting localhost also has no flag. Replaces the old serve-time __CHROME__ substitution.
    q = if inset?, do: "?frameless=1", else: ""
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

  # After the inset shim applies FullSizeContentView (async, on the main thread), the
  # client area grows into the old title-bar strip — refit the webview so it fills it.
  def handle_info(:refit, s) do
    resize_content(s.frame, s.view)
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def handle_cast(:close, s) do
    :wxFrame.close(s.frame)
    {:noreply, s}
  end

  def handle_cast({:eval_js, js}, s) do
    if Autopoet.Window.Mac.available?(), do: Autopoet.Window.Mac.eval_js("autopoet", js)
    {:noreply, s}
  end

  # Real minimize (dock genie). This used to be a no-op: a caption-less frame isn't
  # miniaturizable on macOS. Resolved by the inset shim — the frame is now a proper
  # titled window (miniaturizable), just visually bare, so wx's iconize maps to a live
  # -[NSWindow miniaturize:]. iconize/2 wants the OPTIONS keyword form, not a bare bool.
  def handle_cast(:minimize, s) do
    :wxTopLevelWindow.iconize(s.frame, iconize: true)
    {:noreply, s}
  end

  # The custom green button = REAL macOS fullscreen (its own Space, three-finger
  # swipeable between fullscreen apps) — what the green button means everywhere else
  # on the platform. Same action toggles back out. The wx zoom toggle remains only as
  # the shim-missing fallback (where the window has a native title bar anyway).
  def handle_cast(:maximize, s) do
    if Autopoet.Window.Mac.available?() do
      Autopoet.Window.Mac.toggle_fullscreen("autopoet")
      {:noreply, s}
    else
      if s.maximized do
        :wxWindow.setSize(s.frame, s.restore_rect)
        {:noreply, %{s | maximized: false}}
      else
        {px, py} = :wxWindow.getPosition(s.frame)
        {sw, sh} = :wxWindow.getSize(s.frame)
        :wxWindow.setSize(s.frame, usable_area())
        {:noreply, %{s | maximized: true, restore_rect: {px, py, sw, sh}}}
      end
    end
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
