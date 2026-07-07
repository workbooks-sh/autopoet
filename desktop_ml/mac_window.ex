defmodule Autopoet.Window.Mac do
  @moduledoc """
  Native macOS NSWindow shim (the `hiddenInset` title-bar look) for the desktop
  window — see `c_src/ap_mac_window.m`. Loaded as a NIF; if the shared object is
  missing (never built, or a non-mac target that somehow reaches here), every
  function degrades to a `:not_loaded` no-op and `available?/0` returns false, so
  `Autopoet.Window` falls back to a plain native title bar. Desktop-only (this file
  lives in `desktop_ml/`, which the cloud target does not compile).
  """
  @on_load :load_nif

  def load_nif do
    :autopoet
    |> :code.priv_dir()
    |> :filename.join(~c"ap_mac_window")
    |> :erlang.load_nif(0)

    # Never let a failed NIF load crash module loading — the stubs below stay in
    # place and available?/0 reports false. Always :ok.
    :ok
  end

  @doc "True when the native shim compiled and loaded (macOS with the built .so)."
  def available?, do: loaded() == :ok

  # NIF stubs — replaced by the native implementations when the .so loads.
  def loaded, do: :not_loaded
  def apply_inset(_title), do: :not_loaded
  def miniaturize(_title), do: :not_loaded
  def zoom(_title), do: :not_loaded
end
