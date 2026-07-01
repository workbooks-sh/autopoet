# autopoet

The autopoet as a **desktop app** — the local testbed for Autopoiesis v3
(`workbooks/autopoet-chamber/PLAN.md`). Containment first: this is deliberately a
visible, closeable Mac app rather than a background daemon.

## The containment contract (v0, verified)

- **The window is the kill switch.** One native macOS window (OTP `:wx`, no webview,
  no extra deps): white, debug log down the middle. Closing it halts the entire BEAM
  — verified: `close → wx close_window → :init.stop`, process exits, discovery file
  removed. The autopoet cannot outlive its window.
- **Terminal off switch**: `./autopoetctl status|log|tail|arm [every]|disarm|close|kill`
  — reads `{port, token}` from `data/ctl` (written at boot, removed at shutdown;
  stale file = dead app). Mutating verbs need the per-boot bearer token.
- **Watchdog**: memory > 1200MB soft cap → heartbeat disarmed; > 1500MB hard cap →
  VM halts. Overrides: `AUTOPOET_MEM_SOFT_MB` / `AUTOPOET_MEM_HARD_MB`.
- **Disarmed at birth**: the autopoet heartbeat (`Nexus.Autopoet.Worker`) never runs
  unless explicitly armed. Every boot starts disarmed.
- **Isolated state**: nexus boots as a library dep with `WB_DATA=./data/nexus` — it
  can never touch the dev or cloud nexus.

## Run

```sh
./run.sh                       # opens the window; close it to stop everything
AUTOPOET_HEADLESS=1 ./run.sh   # no window (CI); ./autopoetctl kill to stop
```

## Roadmap (goal doc: workbooks/autopoet-chamber/PLAN.md)

- v0 ✅ containment shell (this)
- v1 — Phase 0: `cause:` stamps + `effect.settled` (nexus lib), telemetry persisted,
  capture recorder always-on under `data/traces/`
- v2 — live shadow layer: Hebbian weights + surprise predictor on the real bus
- v3 — proposal-only brain: two-model proposer via `Nexus.Llm`, `autopoetctl
  accept/reject` as the human gate
