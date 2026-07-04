# The Eval & Genesis Plan — training the autopoet, proving the corpus, starting the world right

Status: LIVING PLAN (v1, 2026-07-04). Edits welcome any time — but every GATE below is
pre-registered: changing a gate's threshold or definition is itself a recorded act (a new
line in `eval/history.log` + a dated edit here with a reason), never a mid-run adjustment.
That is the whole discipline: we may ideate freely; we may not move goalposts silently.

Produced by a 9-agent think-test-rewrite pass: first-boot audit, empirical post-onboarding
probe, integrations audit, public eval-practice research, cold-start/pretraining research,
3-way genesis design competition + judge. Sources inline.

---

## 0. Direct answers first

**Do we have enough integrations?** Yes. The eval suite is hermetic by design (no LLM, no
network) — zero accounts needed to run and extend it. For the LIVE program, Cloudflare +
Google + GitHub + OpenRouter + Polar cover everything planned; the gaps are CODE, not
accounts: (a) stored OAuth tokens have **zero consumers** — the M5 thin clients
(GitHub/Cloudflare/Drive) are unbuilt and there is no bridge from `Autopoet.Connections`
to limb-visible auth; (b) Composio is half-wired — catalog/connect work (the quiz uses
them), but `Composio.execute/2` and `mcp_url/1` have **zero callers**, so connected apps
are collect-only trophies; (c) Polar sandbox is fine for eval-side reward experiments.
OpenRouter is the one critical-path key (planner/drafter/limbs). No new accounts needed —
Phase E below is the code that makes the existing five earn their place.

**Are we training ahead of time for users?** No gradient training per user — and that is
correct, per the personalized-federated-learning literature (FedPer/Per-FedAvg: share a
base, personalize locally; meta-learn an *initialization*, not an answer). What we ship
ahead of time is the **template genome**: (1) a reflex-rule library — weights-as-code
`.work` units, the highest-value pretrained artifact we have (spike 2's amortization);
(2) edge-weight priors as **Dirichlet-style pseudo-counts** with small mass (~50–200
events) so a wrong prior is structurally cheap — live traffic washes it out in minutes
(the chamber's 0.020-vs-0.201 birth-prior failure becomes impossible to ship); (3)
semantic birth edges from `Nexus.Embed`; (4) fleet-tuned constants. Everything else
learns on-device from event 1.

**Should weights be recorded?** Yes — per tenant: pathway snapshot rows (src, dst, kind,
weight, raw_count, last_bump_at + a provenance header: eta/decay/prior_version/schema),
the append-only event trace (we have it — it is the ground truth; snapshots are caches
reproducible by replay), drift state, the reward ledger with causation ids, reflex
provenance (which escalation created each installed rule, its scores, its hit count —
the fleet-promotion signal), and **eval fingerprints**: birth score vs blank baseline at
fixed checkpoints (150/800 events) — the metric class that caught 0.020-vs-0.201.
Fleet-side: only clipped, noised, template-relative count vectors from consenting
tenants, k-anonymous (Gboard/zCDP precedent). Tenant-authored loci are unaggregatable by
construction — they never leave.

**Embeddings?** Yes, bounded: **embeddings nominate; counts elect.** Static precomputed
prior + miss-fallback through the existing `Nexus.Embed` seam — semantic birth edges at
template build, nearest-neighbor candidate edges when the count graph has no path (which
then earn Hebbian weight or decay away), fleet-side locus alignment. NO per-user embedding
training, NO vectors inside the online loop: at tenant scale, tuned count/graph methods
beat embedding methods (Dacrema et al., RecSys 2019), and the online loop needs
microsecond gradient-free CPU reads.

---

## 1. What the probe found (why genesis is Phase A)

Empirical, from disk: the "jumbled mess" is REAL and is ~90% our own seeds, not user data.
Offenders: `welcome.md` (which literally re-creates itself after the human files it away —
notes.ex documents this), `journal.work` with a fabricated 2023-10-27 diary entry,
`todos.work` shipping a stale demo todo that backlinks a nonexistent `[[business-plan]]`,
starter `index.work`, 10 guide pages rendered as 10 graph nodes, `research.work`
hardcoded to the body root (limbs.ex:140), `first-proposal.md` dropped at the vault root.
Fresh boot: 16–17 graph nodes, **15 of which the user never made**. Also confirmed: the
`studio` slug collision (audience-creator and site-builder personas both map to `studio`).

## 2. Genesis architecture (design-competition winner: INVARIANT-FIRST CHASSIS)

Three designs competed (minimal-delta / genesis-first / eval-driven); the judge scored
45/44/37 and synthesized a winner-plus. Core mechanism — **classification + client hide,
NOT a dotdir**: a `.system/` directory was explicitly rejected after a codebase check
found 18 `Path.wildcard` sites where hidden files would go dead (history restore would
silently drop them — hidden-but-dead organs).

The invariants (each is an eval gate in `genesis_eval_test.exs`):

- **I1 blank-slate boot**: fresh home, boot seeds only → visible graph payload == [self].
- **I2 graph budget**: post-onboarding visible nodes == the persona's workspace manifest
  exactly (golden manifests generated by a mix task from the genome — the genome IS the
  manifest source). Zero demo files, ever.
- **I3 hidden ≠ invisible**: default_hidden = {guide, system, library} ships SERVER-side
  in the payload; client persists; an "N hidden" pill + reveal-on-search keeps hiding
  honest.
- **I4 vault starting-code**: the accepted first proposal materializes sectioned pages —
  `## what this is / ## how it fills / ## first moves` — generated deterministically from
  `priv/genomes/<intent>-<road>/*.md.eex` (zero-LLM Lane A; Lane B personalization treats
  the ## sections as protected structure).
- **I5 bijection**: `<ws>/<page>.md` (vault) ↔ `<ws>/<page>.work` (body) — every visible
  page has its machinery twin; nothing else at either root.
- **I6 undoable genesis**: everything arrives as ONE revertible proposal; reject → clean
  void + re-propose path.
- **I7 no root strays**: research limb routes to `<ws>/research`; the brief nests inside
  the workspace; slug uniqueness at intake (`ws`, `ws-2`) — site-builder persona slug
  becomes `site`.
- **I8 genome earns its keep**: birth score (prequential @150/800 events) of
  genome-seeded vs blank ≥ 0 delta — measured, because the chamber proved authored links
  alone score 0.020 vs 0.201 blank.

Migration: propose-don't-delete — existing installs get an "attic" proposal moving demo
seeds out; dual-key detection for one release.

Ship order: **week 1** — the verified 6-file delta (kill seeds; classify in
world_graph.ex; hide defaults; nest brief; sectioned vault pages; genesis_eval_test.exs).
**week 2** — genomes as EEx templates, slug uniqueness, research routing, server
default_hidden, sim-data filtering.

## 3. Eval program upgrades (what public practice says we lack)

Verdict on our core: prequential-replay-vs-baselines is the canonical stream-learning
evaluation (Dawid 1984; Gama et al., ML 2013 — interleaved test-then-train is THE
protocol; MOA/river default). Keep it. Conditions attached, which become goals below:

ADOPT (mapped to gates in Phase B):
1. **Error bars everywhere** — paired CIs, clustered SEs (clustering inflates SE up to 3×),
   power analysis before pre-registering thresholds (Anthropic/Miller, arXiv:2411.00640).
2. **pass^k not pass@k** for reliability claims — the actuator gates on all-trials-succeed
   (tau-bench: 90% per-trial = 57% at k=8).
3. **Holdout traces + canary GUIDs + periodic refresh** — iterating against a fixed replay
   corpus is training-on-test (Kapoor et al., arXiv:2407.01502; GSM1k).
4. **Windowed/fading-factor prequential** — cumulative-from-origin is provably pessimistic;
   only windowed converges to holdout (Gama 2013). We currently report cumulative: fix.
5. **Task-validity audits** — every persona task ships a committed reference solution;
   graders property-tested against degenerate outputs (ABC, arXiv:2507.02825: broken
   graders inflated scores up to 100%; SWE-bench Verified dropped 68.3% of tasks).
6. **Cost columns** on every scorecard row (tokens/$/wall-clock) — accuracy-only gates get
   gamed by retry loops.
7. **Error taxonomy** — invalid-action/format/timeout counted separately from wrong-answer.
8. **Transcript review ritual** — read sampled transcripts every scorecard cycle.
9. **Red-team the gates** — rotate the Goodhart basket membership; a fixed, known basket
   is itself gameable (Apollo "Science of Evals").
10. **Saturation watch** — flat-100% means the instrument stopped measuring; retire/harden
    and version the scorecard schema. (Our select tournament already hit this at k=3 —
    all variants tied; k=1 restored discrimination. The lesson generalizes.)
11. **Negative tasks** — should-NOT-act cases so the actuator can't optimize one-sidedly.
12. **Benchmark the drift detector itself** — injected drift at known points; report
    detection delay AND false-alarm rate (Gama 2014 survey protocol).

AVOID (standing warnings): single-seed illusions, shuffling traces (destroys temporal
validity), path-specific grading (score outcomes, not trajectories), shared state between
trials, headline single-number scorecards, harness-blaming blind spots.

Task-suite shape for persona use-cases (Phase C): GAIA-style tiering (L1 ≤5 steps / L2
5–10 / L3 long-horizon), one verifiable artifact per task (exact-match scoring, no judge),
SWE-bench-Verified-style human validation + difficulty labels, AgentBench-style per-domain
metric choice + failure taxonomy, fail-to-pass AND pass-to-pass assertions per task.

## 4. The goals (measurable, outcome-oriented, pre-registered)

Every goal: METRIC + GATE + EVIDENCE LOCATION. Advance = gate green in `mix eval` +
history line. We are free to edit/ideate anywhere; gate changes get logged.

### Phase A — Genesis (the world starts right) — target: 2 weeks
| Goal | Metric | Gate |
|---|---|---|
| A1 blank slate | visible nodes, fresh boot | == 1 (self) |
| A2 graph budget | visible nodes post-onboarding vs golden manifest, all 6 personas | exact match, 0 demo files |
| A3 starting code | vault pages parse + carry the 3 protected sections, per persona | 6/6 personas |
| A4 undo/void | reject-first-proposal → vault empty → re-propose works | green |
| A5 no strays | files at body/vault root beyond manifest | 0 |

### Phase B — Eval hardening (trustworthy numbers) — target: 2 weeks, parallel with A
| Goal | Metric | Gate |
|---|---|---|
| B1 error bars | history lines carrying n + CI (clustered) | 100% of replay/armlift lines |
| B2 reliability | actuator scored pass^k, k≥3 | reported per scorecard |
| B3 holdout | dev/holdout trace split + canary GUIDs planted | holdout untouched by tuning (audit) |
| B4 windowed preq | windowed + cumulative both reported | all replay lines |
| B5 grader audit | persona tasks with reference solutions | 100% of Phase C tasks |
| B6 detector bench | injected-drift delay + FA rate vs pinned envelope | within E3 envelope |
| B7 negatives | should-NOT-act cases in actuator suite | ≥ 20% of cases |

### Phase C — Corpus proving (the point of it all) — target: weeks 3–6
| Goal | Metric | Gate |
|---|---|---|
| C1 prod corpus | days of wb-dogfood traces replayed in history (wb-mdk4.5) | ≥ 14 days |
| C2 live arm lift | decided real verdicts; CI-backed lift | n ≥ 50; ship/no-ship decision recorded |
| C3 task suites | personas × tasks × tiers, exact-match artifacts | 6 × ≥5 tasks, pass^3 reported |
| C4 learning lift | windowed hebb − frequency on holdout prod traces | > 0 with 95% CI excluding 0 |

### Phase D — Genome (pretraining, done right) — target: weeks 4–8
| Goal | Metric | Gate |
|---|---|---|
| D1 genome birth | prequential @150/800 events, genome vs blank | delta ≥ 0 (never worse than blank) |
| D2 artifact schema | reboot + replay reproduces snapshot | byte-exact |
| D3 embed edges | birth score with vs without semantic edges | delta measured + recorded |
| D4 fleet spec | consent flag + aggregation spec (clip/noise/k-anon) | spec merged; LOO test pre-registered (needs ≥20 tenants) |

### Phase E — Execution lane (integrations earn their place) — target: weeks 3–5
| Goal | Metric | Gate |
|---|---|---|
| E1 auth bridge | Connections → limb-visible auth + thin GH/CF/Drive clients | Lane C authenticated enrichment eval green |
| E2 Composio execute | connected toolkit → agent invokes a real tool in sandbox | ≥ 1 e2e persona eval green |
| E3 reward wiring | Polar sandbox event → outcome ledger reward entry | e2e eval green |

## 5. Operating rhythm

- `mix eval` per commit (fast tier); nightly slow tier (long soak + prod replay) once C1 lands.
- Scorecard review ritual: read history diff + 2 sampled transcripts; check saturation.
- Failures file via `Eval.Drain` → bd. The eval loop replenishes its own work queue.
- Quarterly: red-team the gates; rotate the Goodhart basket; refresh holdout traces.
