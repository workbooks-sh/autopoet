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
    # Load the .work deploy manifest (WB_DATA/index.work: home=/auth=/database=)
    # so Nexus.Server rebases the `home` surface to `/`. Nexus runs as a library
    # dep here (its own Application doesn't boot Config), so we boot it ourselves.
    Nexus.Config.boot()
    port = port()
    root = Path.join([Autopoet.Discovery.home(), "app", "home"])

    # Compile the `.work` BEAM tier NOW — before the supervision tree — so every
    # server-block module the app supervises, `Autopoet.Spine` first among them, is a
    # loaded module by the time its child slot starts. This makes the dependency
    # EXPLICIT rather than relying on Nexus.Server's own bringup side-effect firing at
    # the right moment; Nexus.Server (child 1) re-runs bringup, but the nexus compile
    # cache is content-addressed, so that second pass is a cache hit, not a recompile.
    Nexus.Compile.workbook(root)

    # v0-nexus tree — three top-level boundaries; the fat domain child list now
    # lives in the `.work`-authored `Autopoet.Spine` (app/home/backend/spine.work):
    #
    #   1. Nexus.Server — owns HTTP on the port the window points at, serves the
    #      `.work` app surface (app/home) at `/`. All ~166 routes are server blocks
    #      (P1); Autopoet.Control + its Bandit are RETIRED — the runtime owns HTTP.
    #   2. Autopoet.Spine — the app's own domain/brain processes (P2). Handed as an
    #      explicit map spec (start: mfa, no upfront `child_spec/1`) so the Supervisor
    #      never touches the module until its slot actually starts.
    #   3. Autopoet.Window — the desktop kill-switch (closing it halts the BEAM).
    children =
      [
        {Nexus.Server, root: root, port: port},
        %{
          id: Autopoet.Spine,
          start: {Autopoet.Spine, :start_link, [%{port: port}]},
          type: :supervisor
        }
      ] ++ window()

    result =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: 10,
        name: Autopoet.Supervisor
      )

    seed_workbook()
    Autopoet.Guide.seed()
    Autopoet.Notes.seed()
    # the OOTA recipe library, mirrored read-only into the world (/work/oota) — a
    # LIBRARY agents read, never a host process (canon: no native execution)
    Autopoet.Oota.seed_reference()
    seed_limbs()
    Autopoet.Limbs.register_from_body()
    wire_brain()
    # Phase E: the app.execute effect (connected tools) rides the open effect
    # registry — the runtime stays neutral, the app supplies the integration.
    Autopoet.Integrations.install_effect()

    # Warm the shell caches (sh.c wasm build + the 9.6MB coreutils registry decode) OFF the boot
    # path — cold, the first agent/voice shell call pays ~10s inside its own 10s timeout (wb-p28l9).
    Task.start(fn -> Nexus.Shell.warm() end)

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

  # GENESIS (wb-h0tjs.1, invariant I1): a fresh body starts EMPTY — no starter
  # index/journal demo pages. The user's world is born from the intake proposal;
  # until then the graph shows exactly the self. Only the directory is ensured.
  defp seed_workbook do
    File.mkdir_p!(Nexus.Paths.data_dir())
  end

  # The domain child list (log/history/shadow/desktop-I/O/discovery/desks) now lives in
  # the `.work`-authored `Autopoet.Spine` (app/home/backend/spine.work) — this module is
  # just the OTP bootstrap + one-shot world seeds.

  @doc "Is this the cloud profile (a vendored Fly machine), not the desktop?"
  def cloud?, do: System.get_env("AUTOPOET_TARGET") == "cloud"

  defp window do
    headless? =
      cloud?() or
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
