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

  # sizer constants (wx.hrl macros)
  @wx_vertical 8
  @wx_expand 0x2000
  @wx_align_center_h 0x0100
  @wx_all 0x00F0

  @impl true
  def init(nil) do
    :wx.new()
    frame = :wxFrame.new(:wx.null(), -1, ~c"autopoet", size: {760, 640})
    :wxWindow.setBackgroundColour(frame, {255, 255, 255, 255})

    text = :wxTextCtrl.new(frame, -1, style: @wx_te_multiline ||| @wx_te_readonly)
    :wxWindow.setBackgroundColour(text, {255, 255, 255, 255})

    sizer = :wxBoxSizer.new(@wx_vertical)

    case avatar_bitmap(frame) do
      nil ->
        :ok

      bmp_ctrl ->
        :wxSizer.add(sizer, bmp_ctrl, proportion: 0, flag: @wx_align_center_h ||| @wx_all, border: 16)
    end

    :wxSizer.add(sizer, text, proportion: 1, flag: @wx_expand)
    :wxWindow.setSizer(frame, sizer)

    :wxFrame.connect(frame, :close_window)
    :wxFrame.show(frame)

    Autopoet.Log.subscribe()
    for line <- Autopoet.Log.recent(100), do: append(text, line)

    {:ok, %{frame: frame, text: text}}
  end

  # The face of the nexus (Autopoet.Avatar), rasterized locally via macOS QuickLook
  # (qlmanage) — no network, no extra deps. Any failure degrades to no avatar.
  defp avatar_bitmap(frame) do
    dir = Path.join(Autopoet.Discovery.home(), "data")
    File.mkdir_p!(dir)
    svg_path = Path.join(dir, "avatar.svg")
    File.write!(svg_path, Autopoet.Avatar.svg())

    {_, 0} = System.cmd("qlmanage", ["-t", "-s", "280", "-o", dir, svg_path], stderr_to_stdout: true)

    image = :wxImage.new(~c"#{svg_path}.png")

    if :wxImage.isOk(image) do
      :wxStaticBitmap.new(frame, -1, :wxBitmap.new(image))
    else
      Autopoet.Log.puts("avatar: rasterized PNG unreadable — continuing without a face")
      nil
    end
  rescue
    e ->
      Autopoet.Log.puts("avatar: skipped (#{Exception.message(e)})")
      nil
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
