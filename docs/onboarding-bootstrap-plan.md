# The Intake Agent — from quiz answers to a living first world

Full-scale plan for the post-onboarding bootstrap: an agent session that runs
BEFORE the user first sees the dashboard, builds a demo workspace from the quiz
answers with absolutely no data, optionally enriches itself from connected
GitHub / Google Drive / Cloudflare (consent-scoped, user-picked), and comes to
the table with **the first proposal** — a built world plus a go-forward brief.

## 0. The moment we own

Between "enter autopoet — watch it run" and the first dashboard paint. At that
moment we hold:

- `data/profile` — every quiz answer, every dictated/typed note
  (`<question>.notes`), and the compiled `plan.*` lines
  (workspace / agents / rules / connect / setting / fleet / firstrun)
- `Autopoet.Auth.connections()` — which of github/google/cloudflare are
  connected (stubs today; real OAuth is wb-y9of)
- nothing else. Zero data is the design constraint, enrichment is the bonus.

## 1. Principles

1. **Zero-data must produce a complete world.** The `plan.*` lines are already
   a compiled spec; a deterministic expansion of them must yield a working
   workspace with no network, no keys, no luck.
2. **Enrichment is invited, never taken.** Per connected provider we ask ONE
   scoped question with a picker (repos / zones / docs). We read exactly what
   was picked, nothing else, and record what was read as profile lines.
3. **The deliverable is a proposal, not a fait accompli.** The demo workspace
   is the agent's own body (direct, undoable); the go-forward brief lands as a
   PENDING proposal the human accepts or rejects — the existing human gate.
4. **Everything is text.** Profile lines in; `.work` files out; the brief is a
   file; the consent record is lines. No JSON, no sidecar state.

## 2. What already exists (inventory)

| piece | where | role in this plan |
|---|---|---|
| work queue | `Autopoet.Requests.file/2` → drained by `Brain.cycle` → `Nexus.Autopoet.Worker.run_once` | how bounded agent work enters the system |
| two-model brain | `Autopoet.Brain.propose/1` — planner (OpenRouter) with progressive disclosure over `Autopoet.Guide`, drafter (Mercury/OpenRouter), `parse_files` → file blocks | the personalization pass reuses this exact shape |
| the body | `Autopoet.Body.apply/2` — direct writes to the agent's own `.work` structure, full undo/redo history | where the demo workspace materializes |
| the human gate | `Autopoet.Proposals.record/3` → pending → `/proposals` + `/proposal/:id/accept|reject|revert` (control.ex:579–620; accept applies against the VAULT and re-triggers translation) | fully built and — notably — has ZERO production callers today; the intake is its FIRST real producer |
| living agents | `Autopoet.Limbs.register_from_body/0` — `agent :name` blocks in body files register at boot AND hot-reload on accepted proposals; `Limbs.dispatch/3` runs one | plan.agent entries become real, running limbs |
| aux LLM | `Autopoet.Chat.oneshot/2` (system+user → completion; test-injectable `:chat_llm`) | small rewrites that don't need the full brain |
| answers | `Autopoet.Profile.all/0` / `render/0` | the input contract |
| world render | `world_graph.ex` — body docs + backlink edges + limbs + PENDING PROPOSALS + requests as nodes | the built pages AND the pending first proposal ARE the first-paint graph |
| vault vs body | vault = human's `data/notes` (`.md`, workspaces = folders with a `.workspace` marker via `Notes.create(rel, "workspace")`); agent PROPOSES there, never writes | the human-facing workspace can arrive AS the proposal |
| enrichment reach | agent host web verbs (fetch/scrape/search) behind `grant net` (nexus bash.ex); tokens via `Nexus.Secrets` | Lane C needs no new HTTP clients for public APIs |
| money/bounds | nexus admission boundary; wall-clock timeouts only (no turn caps, per canon) | session budget |

## 3. The pipeline

### Lane A — deterministic skeleton (zero data, zero keys, always works)

`Autopoet.Intake.skeleton/1` — pure function of `Profile.all()`:

- `plan.workspace: shop — orders, listings, money watch` →
  `shop/index.work` + one page per listed page-name, prose seeded from the
  intent/road answers ("orders" page opens with what it will hold and why).
- `plan.agent.N: shopkeeper — watches orders and stock…` →
  an `agent :shopkeeper` block in `shop/agents.work` with the standing job as
  its charter, leash/pings/oops answers baked in as its policy lines.
- `plan.rule.N: when an order lands, log it…` → a rule page holding the plain
  words as prose plus the SIMPLEST runnable expression of it (a hook whose
  match/run is real but inert until its trigger source exists), tagged
  `#proposed` so the UI shows "tap to arm".
- `plan.setting` / `plan.fleet` → the workspace's settings block.
- question notes (`git.notes`, etc.) → an `intake/briefing.work` page the
  agents read — the user's own words, verbatim, attributed per question.
- `plan.firstrun` → `intake/firstrun.work` describing the ignition moment.

Deterministic, tested with golden profiles, never blocked on network. Applied
via `Body.apply` (undoable), then `Limbs.register_from_body()` — the world is
ALIVE even if every key is missing.

SPLIT WORTH MAKING: the MACHINERY (agent blocks, rules, briefing, context)
lands in the BODY — alive immediately, agent-owned. The HUMAN-FACING workspace
(the vault folder with its pages — "orders", "today", "paper trail") arrives
as part of THE PROPOSAL (Lane D): accepting it materializes the workspace into
the vault via the existing accept path. One tap = "yes, set my world up like
this." (Vault writes via `Notes.write` file translation requests — use meta
type "context" for briefing-style pages, or let the queued translations be the
first heartbeat's work, which is honest theater.)

### Lane B — LLM personalization pass (bounded, optional)

One brain-shaped session (planner+drafter, same `parse_files` contract) whose
request is: the skeleton files + `Profile.render()` + the industry answer +
all notes. Its charter:

- rewrite page prose in the user's vocabulary (industry: "performance
  creative" ≠ "technology" — the corpus expansion feeds this),
- flesh the first rule from inert-but-real into genuinely runnable against
  whatever exists locally (filesystem watch, schedule, tag),
- name things the way this user talks (notes are gold here).

Output → `Body.apply` again. If keys are absent or the call fails: skip —
Lane A already shipped a complete world. Wall-clock bounded; admission-metered.

### Lane C — enrichment interviews (consent-scoped scans)

Shown AFTER the quiz finale, one screen per CONNECTED provider, skippable:

- **github** — "you connected github. pick repos worth reading." (chip-pick
  from the repo list) → fetch per pick: README, top-level tree, languages.
- **cloudflare** — "pick zones i should know about." → zone list → DNS/site
  facts per pick.
- **google drive** — "share docs that explain your world." (search box over
  Drive) → picked docs' text.

Each pick lands as `intake/context/<provider>-<name>.work` in the body and as
a `scan.<provider>: a,b` consent line in the profile. Lane B consumes these as
context. Anything unpicked is never read — and we say so on the screen.

Mechanism that exists TODAY: a bootstrap limb (copy the seeded
`research_limb` shape) with `grant net`, dispatched via
`Limbs.dispatch(name, task, file_to: ...)` — the host web verbs
(fetch/scrape/search, SSRF-guarded) reach public APIs with zero new plumbing;
authenticated reads take tokens from `Nexus.Secrets` once real OAuth lands
(wb-y9of). Ships LAST; Lanes A+B must never wait for it.

### Lane D — the first proposal + proposal-first entry

1. `Intake.brief/1` renders `brief.work` — what got built, what runs right
   now, the next three moves, which integrations to connect and why (ordered
   by plan.connect), and what the agent would do with each. Written with
   `Chat.oneshot` (or template-only if no keys).
2. `Proposals.record(%{target: "intake-brief", ...}, changes)` — PENDING, on
   existing plumbing.
3. First dashboard load: if a pending intake proposal exists, the app opens on
   a **proposal overlay** — the brief on top, the LIVING graph visible behind
   it, `plan.firstrun` already firing (nodes lighting up). Buttons: "accept
   the plan" (`/proposal/:id/accept`), "let me look around first" (stays
   pending in the normal proposals inbox), "not like this" (reject + notes).
   This is the product's thesis in one screen: it files its own work; you hold
   the pen.

### Ignition (the firstrun moment)

After Lane A applies: fire the demo — `Limbs.dispatch(starter_agent, canned
first task)` or emit the rule's synthetic trigger event onto the bus — so the
world is MOVING behind the proposal overlay, not a museum. Per intent, the
canned task comes from the plan.firstrun line (bootstrap-planner mapping).

## 4. Orchestration & timing

- Start Lane A the moment the quiz FINALE renders (not at button press) — the
  seconds the user spends reading "your starting world" are free compute; the
  finale gains a quiet status line ("already building — 3 pages so far").
- Lane B runs immediately after, still during finale/enrichment screens.
- `/auth/onboarding/done` waits for NOTHING: if intake is mid-flight, the
  dashboard shows the world growing live (which is better theater anyway).
- Trigger: the `POST /auth/onboarding/done` handler (control.ex) spawns the
  intake Task async (the reload is never blocked), guarded by a
  `data/bootstrapped` marker so it runs exactly once per install.
- Supervision: Task under the app supervisor; bounded by wall-clock timeout +
  the admission money boundary; idempotent (re-running overwrites its own body
  files, never duplicates proposals — one pending intake proposal max).
- Live theater: the dashboard's existing `/sse` log stream + `limb.returned`
  events narrate the build in real time if the user lands mid-flight.
- Outcomes feed `Nexus.Autopoet.Knowledge` (append-only knowledge.work) like
  every other worker result — the intake teaches the brain about this user
  from minute zero.

## 5. Verification

- **Golden profiles**: the six persona paths (canned `data/profile` fixtures)
  → Lane A output parses (`Nexus.Autopoet.Eval.validate` / work check),
  `agent :` blocks register, brief records exactly one pending proposal.
- **No-keys test**: `brain_live: false` → Lanes A+D complete, B skipped, world
  still alive.
- **Consent test**: Lane C fixtures — nothing outside picked items is fetched
  (assert on the client seam), consent lines written.

## 6. Milestones (bd)

1. **M1** `Autopoet.Intake` Lane A — skeleton expansion + ignition + golden
   tests. (No dependencies; biggest win.)
2. **M2** Lane D — brief + proposal + proposal-first entry overlay.
3. **M3** Lane B — personalization pass (reuses Brain internals; needs keys).
4. **M4** finale status line + start-at-finale orchestration.
5. **M5** Lane C — enrichment interviews (BLOCKED on real OAuth, wb-y9of) +
   thin GitHub/Cloudflare/Drive clients.
6. **M6** corpus maintenance: industry corpus shipped as data
   (`quiz-corpus.js`), periodically regenerated.

## 7. Lane E (Lane ∞) — the evaluation suite

The intake profiles are not just onboarding artifacts; they are EVALUATION
SEEDS. Every golden persona (the six from the design round, plus every real
profile shape the quiz can emit) defines a reproducible autopoet environment:
answers + notes + plan.* in, a whole world out. That makes the full agent
system benchmarkable end to end — and it is how the promises the onboarding
MAKES (a darwin gödel machine, it improves itself, nothing is lost) get
VALIDATED instead of stubbed or inferred.

The loop (runs ad nauseam, wall-clock bounded per run, never turn-capped):

1. **Seed** — pick a persona profile; stand up a fresh autopoet home
   (isolated `AUTOPOET_HOME`, the same trick the test env uses) with the
   likely integrations for that persona stubbed or live (the plan.connect
   line already names them).
2. **Intake** — run Lanes A–D; assert the invariants (world parses, agents
   register, exactly one pending proposal, brief promises only what exists).
3. **Live** — accept the proposal, arm the rules, and let the heartbeat run:
   cycles sense → propose → gate → learn (`Nexus.Autopoet.Knowledge`), limbs
   take tasks, failures file requests. Feed it synthetic events matching the
   persona (orders landing, emails arriving, files appearing).
4. **Score** — per run: proposal acceptance-worthiness (does the Eval gate
   pass its own output), rule-arming success, request→resolution latency,
   knowledge.work growth, hebb/surprise signal movement
   (`Autopoet.Shadow.Hebb` / `.Surprise` — the ML concepts made measurable),
   and world-integrity invariants (undo always works, no vault writes outside
   accepted proposals, grants never widen).
5. **Select** — the darwin gödel part, made real: run variant configurations
   (prompt variants, model variants, policy defaults) against the same seeds;
   keep what scores better; the evolution vignette in the onboarding deck
   stops being a metaphor.

Fix/repair/build elasticity: every failure the loop surfaces is filed via the
existing `request self` channel — the eval harness drains those into bd
issues, so the loop's output is a continuously replenished work queue against
the real system. This lane starts ONLY after A–D ship; A–D are its substrate.
