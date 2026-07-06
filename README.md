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
- v4 ✅ resident micro-brain + BEAM-native companion analysis — the shadow layer
  runs a local decision limb (`Autopoet.Micro`, a small model served by
  llama-server on the free/local lane, bills no one) that on a drift alarm picks
  the first diagnostic action (`Shadow.Triage`, advisory only — same containment
  rung as `Hebb.recall`; degrades to the prior behaviour when the model is
  absent). The always-on capture corpus feeds two native-Nx tools — `Shadow.Trace`
  (the k-order structure gate over the real event stream) and `Shadow.Profile`
  (Scholar `GaussianMixture` behavioural clustering of loci into spine vs
  decision bands) — no Python sidecar, ever. A learned assessor earns its place
  only by beating the first-order detector on the gate; that gate is part of the
  loop, not a preamble to it.
- next: grow the organic corpus from real runs → the gate confirms where a
  learned assessor beats first-order → the online minGRU trainer + `Profile`
  extended to temporal decision-collapse detection; Burrito bundling once earned

## The face

The window and control page show the nexus's face — composed locally from the
vendored [notionists-neutral](https://www.dicebear.com/styles/notionists-neutral/)
part library (Notionists by Zoish, CC0 1.0). `vendor/extract.mjs` extracts the
parts into categorized fragments under `priv/avatar/<group>/`; composition is
seeded (`AUTOPOET_SEED`, default `autopoet-1` — same face every boot), glasses
excluded, no API calls. Rasterized for the native window via macOS QuickLook.

## Working convention: BOOTSTRAP vs AUTONOMOUS

Every status report on this project labels which mode produced each result:

- **[BOOTSTRAP]** — a human/Claude did it by hand to seed the baseline (manual
  orchestration, hand-written structure, founding examples). We are knowingly
  role-playing the conductor to generate the training signal.
- **[AUTONOMOUS]** — the system did it itself (limbs, brain proposals, gates).

Rule that goes with it: content-level structure (new limbs, flows, pipeline
stages) enters ONLY via request → autopoet proposes → human gates. Hand-building
is reserved for substrate/mechanism. The goal each week is to move lines from
the first label to the second.

## Prompt-engineering law for facets

The project-management facets — todos, hash notes, flows, the request lane — are
load-bearing, not optional extras. They appear at the HEAD of every prompt,
stated declaratively as what the format *is* ("project memory is part of the
format"), never as abrasive imperatives. Succinct beats emphatic: one exact line
per facet, depth in the guide behind `NEED:`.

## The vault — notes are the source of truth

`data/notes/` is the human's Obsidian-style vault: exactly two file kinds —
`.md` natural-language documents and `.sketch.svg` freehand drawings (drawn in
the app). The vault never contains `.work`; on save, a changed note files a
diff-triggered translation request (one pending per note — latest wins), and the
heartbeat's two-model brain (the audited typeaway pattern: planner structures,
Mercury drafts) proposes the minimal `.work` the note implies, through the human
gate. The world graph shows the translated structures; the vault shows only your
notes. First live run: a plain-English reading-list note became a reading.work
page + a weekly reminder hook in 27s, gated, accepted.
