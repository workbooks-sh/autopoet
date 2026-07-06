# Learners restore their snapshots at app boot (phase 0: nothing is lost). A test
# run must start COLD — the drift-detector envelope and exact-count assertions
# assume no memory of previous runs. Wipe the snapshots, then brutally kill the
# learners (no terminate → no re-persist); the supervisor restarts them cold.
File.rm_rf!(Autopoet.Shadow.dir())

# The request queue reloads .req files at boot (production: a restart must not
# eat a filed issue). In tests that durability compounds: every run's leftover
# requests get drained into every later run's heartbeat cycles — unbounded
# cross-run garbage that eventually blows the beat eval's latency budget. Cold.
File.rm_rf!(Autopoet.Requests.dir())

# Same compounding through the DURABLE telemetry ledger (phase 0.1): failing
# units recorded by past runs re-sense as concerns in every later heartbeat —
# each cycle proposes for the whole history. Trials share no state; wipe.
File.rm_rf!(Path.join(Nexus.Paths.durable_dir(), "telemetry"))

# `Autopoet.Capture` APPENDS to a per-date trace file (`data/traces/<date>.etfs`)
# on every event; across many same-day runs it grows unbounded, and once a single
# world file crosses the shell's 4MB skip cap a recursive `grep` over the body skips
# it and exits non-zero — flaking the SEARCH suite. Each trial starts trace-cold.
File.rm_rf!(Autopoet.Capture.dir())

for name <- [Autopoet.Shadow.Hebb, Autopoet.Shadow.Surprise, Autopoet.Shadow.Outcomes, Autopoet.Requests, Nexus.Telemetry],
    pid = Process.whereis(name),
    is_pid(pid) do
  Process.exit(pid, :kill)
end

Process.sleep(400)

# :live = the real-LLM tier — NEVER runs in mix test / mix eval; only via
# `AUTOPOET_LIVE=1 mix eval.live` (double-locked: tag + env)
ExUnit.start(exclude: [:live])
