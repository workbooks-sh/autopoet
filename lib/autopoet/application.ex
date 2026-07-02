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
        Autopoet.Requests,
        Autopoet.Capture,
        Autopoet.Snapshot,
        Autopoet.Shadow.Hebb,
        Autopoet.Shadow.Surprise,
        {Bandit, plug: Autopoet.Control, ip: {127, 0, 0, 1}, port: port},
        {Autopoet.Discovery, port}
      ] ++ window()

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Autopoet.Supervisor)

    seed_workbook()
    Autopoet.Guide.seed()
    Autopoet.Notes.seed()
    seed_limbs()
    Autopoet.Limbs.register_from_body()
    wire_brain()

    Autopoet.Log.puts("autopoet up — ctl on 127.0.0.1:#{port}; heartbeat DISARMED (arm via ./autopoetctl arm)")
    result
  end

  # v3: inject the proposal-only brain into the heartbeat by registering OVER the
  # neutral "autopoet.cycle" effect (the registry is open by design — the app
  # supplies the brain; the runtime stays generic). Every cycle result is only ever
  # a PROPOSAL; merges happen through autopoetctl accept alone.
  defp wire_brain do
    Nexus.Effects.register("autopoet.cycle", fn _args, _event, _ctx ->
      Autopoet.Brain.cycle()
      :ok
    end)
  end

  # Limb definitions ship in priv/seed and land in the body once (never overwrite —
  # after that, limbs.work is human-editable body content; its agents re-register
  # from the body at every boot).
  defp seed_limbs do
    src = Path.join(:code.priv_dir(:autopoet), "seed")
    root = Nexus.Paths.data_dir()

    for f <- Path.wildcard(Path.join(src, "*.work")),
        target = Path.join(root, Path.basename(f)),
        not File.exists?(target) do
      File.cp!(f, target)
    end
  end

  # A fresh data dir gets a tiny starter workbook — the body the autopoet observes
  # and proposes against. Never overwrites anything.
  defp seed_workbook do
    root = Nexus.Paths.data_dir()

    if Path.wildcard(Path.join(root, "**/*.work")) == [] do
      File.mkdir_p!(root)

      File.write!(Path.join(root, "index.work"), """
      # autopoet nexus

      The local body of the autopoet desktop experiment. See [[journal]].
      """)

      File.write!(Path.join(root, "journal.work"), """
      # Journal

      Notes accumulate here. Tagged #journal.
      """)

      Autopoet.Log.puts("seeded starter workbook in #{root}")
    end
  end

  defp window do
    headless? =
      System.get_env("AUTOPOET_HEADLESS") in ~w(1 true) or
        Application.get_env(:autopoet, :headless, false)

    if headless?, do: [], else: [Autopoet.Window]
  end

  def port do
    case System.get_env("AUTOPOET_PORT") do
      nil -> Application.get_env(:autopoet, :port, 4477)
      p -> String.to_integer(p)
    end
  end
end
