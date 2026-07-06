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

    # Cloud profile: the SAME build runs on a vendored Fly machine as the 24/7
    # agent — no window, no mic STT, no realtime Voice (those are desktop-only
    # I/O), and it binds all interfaces (the machine's own network), not just
    # loopback. The desktop profile keeps everything and stays loopback-only.
    io = if cloud?(), do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

    children =
      [
        Autopoet.Log,
        Autopoet.History,
        Autopoet.Auth,
        Autopoet.Profile
      ] ++
        desktop_io() ++
        [
          Autopoet.Watchdog,
          Autopoet.Requests,
          Autopoet.Capture,
          Autopoet.Snapshot,
          Autopoet.Shadow.Hebb,
          Autopoet.Shadow.Surprise,
          Autopoet.Shadow.Outcomes,
          # P0 — Autopoet runs ON the nexus: Nexus.Server owns the MAIN port (the
          # window points here) and serves the `.work` app surface (app/home —
          # client islands + server blocks) at `/`. Legacy Control drops to port+1
          # (NOT deleted) to serve the routes not yet migrated; P1 moves those into
          # server blocks, then Control retires entirely.
          {Nexus.Server, root: Path.join([Autopoet.Discovery.home(), "app", "home"]), port: port},
          {Bandit, plug: Autopoet.Control, ip: io, port: port + 1},
          {Autopoet.Discovery, port}
        ] ++ [Autopoet.Desks] ++ desk() ++ window()

    # max_restarts headroom: tests hard-kill the three shadow learners to force
    # cold/reboot paths — three near-simultaneous restarts must not take down the tree
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

  # Desktop-only I/O children (mic STT + realtime Voice) — dropped in the cloud.
  # Filtered to modules that actually exist so a mid-refactor tree (a renamed or
  # deleted I/O module) degrades to missing audio, never a boot crash.
  defp desktop_io do
    if cloud?() do
      []
    else
      # Qwen3-TTS is the product engine. Kokoro is booted ONLY when the dev
      # toggle asks for it (WB_VOICE=kokoro or data/voice-engine) — a comparison
      # lens, never the default.
      base = [Autopoet.Stt, Autopoet.Voice, Autopoet.QwenTts, Autopoet.Affect]
      base = if Autopoet.VoiceEngine.kokoro?(), do: [Autopoet.Kokoro | base], else: base

      Enum.filter(base, fn mod ->
        Code.ensure_loaded?(mod) ||
          (IO.puts("autopoet: desktop I/O child #{inspect(mod)} missing — skipped") && false)
      end)
    end
  end

  @doc "Is this the cloud profile (a vendored Fly machine), not the desktop?"
  def cloud?, do: System.get_env("AUTOPOET_TARGET") == "cloud"

  # The always-on trading desk (day/night market cycle) — opt-in via AUTOPOET_DESK=1
  # (machine-identity enablement, like PORT/WB_DATA). Never on in tests by default.
  defp desk do
    if System.get_env("AUTOPOET_DESK") == "1", do: [Autopoet.Desk], else: []
  end


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
