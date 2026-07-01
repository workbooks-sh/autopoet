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

- v0 ✅ containment shell — window kill switch verified end-to-end
- v1 ✅ Phase 0 — `cause:` stamps + `effect.settled` (in the nexus lib, tests green);
  capture recorder always-on (`data/traces/<date>.etfs`, replayable by the chamber's
  `gym/replay.exs`); telemetry snapshots (framed file, Store-backed later)
- v2 ✅ live shadow layer — Hebbian pathways + surprise predictor with the PINNED
  detector on the real bus; drift raises `autopoet.attention` (zero actuators)
- v3 ✅ proposal-only brain — proposer injected into the real heartbeat
  (`autopoet.cycle` effect re-registered app-side; runtime stays neutral); Groq-class
  model via `Nexus.Llm` when `GROQ_API_KEY` is set, harmless skip otherwise;
  EVERYTHING lands as a pending proposal under `data/proposals/`; `autopoetctl
  accept <id>` re-runs the real Eval gate before any file is touched; accept/reject
  events are the labeled B9/B4 stream
- next: real usage → first real concerns → the brain's first real proposals; then
  Burrito bundling once the app has earned it

## The face

The window and control page show the nexus's face — composed locally from the
vendored [notionists-neutral](https://www.dicebear.com/styles/notionists-neutral/)
part library (Notionists by Zoish, CC0 1.0). `vendor/extract.mjs` extracts the
parts into categorized fragments under `priv/avatar/<group>/`; composition is
seeded (`AUTOPOET_SEED`, default `autopoet-1` — same face every boot), glasses
excluded, no API calls. Rasterized for the native window via macOS QuickLook.
