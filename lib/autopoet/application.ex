defmodule Autopoet.Application do
  @moduledoc """
  The autopoet DESKTOP shell — v0 is containment before intelligence:

    * a native macOS window (OTP `:wx`) — plain white, debug log down the middle.
      CLOSING THE WINDOW HALTS THE WHOLE BEAM: the stoplight is the kill switch;
      the autopoet cannot outlive its window.
    * a localhost-only control API + `./autopoetctl` — the terminal-grade off switch.
    * a watchdog — memory soft-cap disarms the heartbeat, hard-cap halts the VM.
    * the nexus runtime boots as a library with its own isolated data dir
      (`data/nexus`, via WB_DATA in run.sh); the autopoet heartbeat is DISARMED at
      every boot — arming is always an explicit human act.

  Headless mode (tests/CI): AUTOPOET_HEADLESS=1 skips the window; every other rail
  stays up.
  """
  use Application

  @impl true
  def start(_type, _args) do
    port = port()

    children =
      [
        Autopoet.Log,
        Autopoet.Watchdog,
        {Bandit, plug: Autopoet.Control, ip: {127, 0, 0, 1}, port: port},
        {Autopoet.Discovery, port}
      ] ++ window()

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Autopoet.Supervisor)

    Autopoet.Log.puts("autopoet v0 up — ctl on 127.0.0.1:#{port}; heartbeat DISARMED (arm via ./autopoetctl arm)")
    result
  end

  defp window do
    if System.get_env("AUTOPOET_HEADLESS") in ~w(1 true), do: [], else: [Autopoet.Window]
  end

  def port, do: String.to_integer(System.get_env("AUTOPOET_PORT") || "4477")
end
