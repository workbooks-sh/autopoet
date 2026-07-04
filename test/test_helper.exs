# Learners restore their snapshots at app boot (phase 0: nothing is lost). A test
# run must start COLD — the drift-detector envelope and exact-count assertions
# assume no memory of previous runs. Wipe the snapshots, then brutally kill the
# learners (no terminate → no re-persist); the supervisor restarts them cold.
File.rm_rf!(Autopoet.Shadow.dir())

for name <- [Autopoet.Shadow.Hebb, Autopoet.Shadow.Surprise, Autopoet.Shadow.Outcomes],
    pid = Process.whereis(name),
    is_pid(pid) do
  Process.exit(pid, :kill)
end

Process.sleep(400)

ExUnit.start()
