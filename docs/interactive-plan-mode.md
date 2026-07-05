# Interactive Plan Mode — the onboarding as a living whiteboard

Replaces the form quiz. When an AI key is connected, onboarding becomes an
**interactive plan mode**: a graph-paper canvas where the Autopoet cube floats,
asks you one question at a time, and *builds your system live in front of you* —
Professor Oak wiring your nexus while he explains it. You approve at the end; the
plan boots.

Gate: **AI connected → plan mode; no AI → the form quiz** (plan mode needs the
LLM to weave the graph). See [[lifecycle-plan]] §onboarding.

Status: DESIGN — grilled out 2026-07-05, not built yet. This doc is the shared
reference; correct anything wrong here before we build.

---

## 1 · The layer model (Inform 7)

The whole thing rests on a two-layer split — the same one Inform 7 has between
its readable source and its compiled machine form.

- **Vault = your Inform 7 source.** Pure natural-language docs: goals, mission,
  preferences, orientation — plus **managed base docs** (a **glossary** of every
  term the app uses; a **`design.work`** that describes the design → becomes your
  design system). *You* write here. **The agent can only PROPOSE changes to the
  vault — never edits it directly.** Human-owned. HITL.

- **Body = the agent's Inform 6 implementation.** Compiled and *woven* from the
  vault — `.work` (executable), Svelte, HTML workbook-apps, polyglot pieces
  running together. The agent writes this directly. It is what actually runs.

- **Graph = the live read-view of the body.** As the agent commits and weaves,
  the graph *shows* it — clusters, nodes, edges ARE the real generated content
  (a `.work` file, an HTML app, a schedule). You primarily **read** it (watch the
  agent think and build), with the option to write. It is not a diagram *of* the
  system — it *is* the agent's working surface.

The graph up top is **free-form** (the middle language); it **compiles down** to
the structured substrate (`client`/`server`/`agent`/`tool` in `.work` stay exactly
as they are). Free-form works *because* there is a compile step mapping it down —
Inform 7 → Inform 6 → bytecode.

### Node types are NOT a taxonomy

We do not define node "types" by a fixed schema. A node can be whatever fits the
user's words — a skill, a tool, a "toolkit thingamajig," an entity, a strategy,
a cluster. Groupings are free-form. The taxonomy lives *below*, in the compiled
`.work`, not in the graph the human reads. Do not force `workspace/agent/
integration/...` on the user; that was our scaffolding, not a law.

---

## 2 · The completeness engine — dynamic coverage

The "how done is it?" math. A **self-expanding rubric**: a guaranteed floor that
can only rise to fit the user's real complexity.

- **Base coverage requirements**, seeded from the start — the must-asks. Each
  carries a **depth threshold**: how much real context counts as "enough" for
  that topic.
- As you answer, the agent measures **depth per requirement**. Shallow → keep
  probing *that* requirement; it does not move on until the depth is there.
- **Branching**: when a topic goes deeper than its requirement holds, or keeps
  recurring, or a new deeper subject surfaces — the agent **spawns a new coverage
  requirement**. The instant it does, that requirement is **mandatory**. The plan
  cannot complete until it is met too.
- **Done = every requirement (base + branched) hits its depth threshold.**

```
completeness = min over all requirements of ( depth_have / depth_need )
branching may ONLY add requirements (raise the bar) — never skip.
approve unlocks when completeness == 1.0 across ALL requirements.
```

The bar can only rise: base gives a floor (never dead-ends, never finishes
shallow); branching raises the ceiling (never over-simplifies). The progress
reading is **honest** — it can move on you as the agent realizes there is more
to understand. That is the truthful thing to do.

Requirements are the state-machine spine; the LLM fills the nodes and phrases the
questions. So it can't wander off (spine) and can't feel like a checklist (LLM
phrasing, one at a time).

---

## 3 · The experience (full choreography)

- **Canvas**: inset with a rounded border + margins on all sides (white frame,
  graph paper inside). Pannable/explorable; a **refocus** control snaps the camera
  back to the active cluster if you've wandered.
- **The cube**: floats near the active area, casts a **pointer beam** to the node
  it's creating, narrates in a **speech bubble** (typed text). Parks bottom-left
  for some moments; moves like the voice widget otherwise.
- **Camera**: eases to the active node/cluster as the graph grows; follows the
  agent / the current stage.
- **Bottom widget**: the question surface — **next / back** buttons. Questions are
  **multiple-choice where they can be** (with room to add a note even then) and
  **open-ended multi-line** where they can't — the latter with a **🎤 mic**
  (Moonshine STT, which we already ship).
- **One question at a time.** The pace is the point — never overload. Think from
  question to question. (This grill-me session is the reference feel.)
- Questions exist to **understand the user** — preferences, directions,
  orientations — not to guess from templates.

---

## 4 · Rendering + tech

Vanilla — the app is framework-less with **D3 already loaded** (`d3.v7.min.js`).

- **D3** draws custom nodes/edges + `d3.zoom` for pan / follow / refocus.
- **ELK.js** computes layout — any topology, not just L-R / T-B, so everything
  has a place but nothing is forced into a lane.
- Custom SVG/HTML node + cluster rendering.
- No React/Svelte, no bundler, no build step.

The graph generation runs **server-side in the brain** (Elixir): the LLM emits
structured deltas (nodes + edges + the next question + coverage updates); the
client renders + animates. Deterministic render from structured output; the choreography is client-side.

---

## 5 · Materialization — approve = boot

Compile timing: **at approve**. You explore/author freely; nothing compiles until
you commit. Then:

- Compile the whole free-form graph → `.work` substrate + weave the body.
- **Drop in editable vault docs** — pre-built where we have them, LLM-authored
  where we don't (see §6). You never start from a blank file.
- **Boot the punch-list**: everything automatable materializes now (workspaces,
  desks, schedules, self-serve integrations). The rest — payment, OAuth consent,
  phone verify, policy — turn **amber "needs you" nodes** with a *connect →* action
  right on the graph. The graph *is* the onboarding punch-list. Matches the
  `[connected]/[self-serve]/[needs-human]` model already locked in [[lifecycle-plan]].

---

## 6 · Vault docs — seeded, not templated

Pre-built editable vault docs come from a **curated library we ship + LLM fills
the gaps**. But the emphasis is NOT templating — the *questions* illuminate what's
needed; preferences are about understanding the user, not preforming guesses.

Base managed docs we can seed + maintain over time:
- **glossary** — every term the app uses, in one place (a living reference).
- **`design.work`** — describes the design → becomes the design system in the vault.

A curated catalog (auth strategies, common integrations like Shopify, git
workflows, project scaffolds) supplies real, battle-tested editable docs when the
graph references them; anything not in the catalog, the LLM authors as a fresh
editable doc. Either way the result is a doc the user OWNS and edits — the body
compiles *from* it, and the agent may only propose further edits to it.

---

## 7 · Governance (who writes what)

- **Vault** — human read + write. Agent writes **only via proposal** (HITL). Your
  goals/mission/preferences/glossary/design are yours.
- **Body + graph** — agent writes directly; human reads (option to write). This is
  the agent's implementation surface — watch it work.
- **Compile** — vault → body (Inform 7 → Inform 6 + polyglot). At approve for
  onboarding; re-runs when the vault changes.

---

## 8 · Build plan (phased toward the full v1)

The target is the full-choreography experience. Sequenced so each phase runs:

1. **Canvas + camera** — inset frame, graph paper, D3 + ELK layout, pan/zoom,
   refocus. Static seed graph to prove layout + camera. **[SHIPPED 2026-07-05:
   priv/static/planmode.js — lazy-loaded elk.bundled.js, stress layout, cluster
   hulls, cube+beam+bubble (early), next/back widget, classic-quiz fallback.
   Dev loop: settings → restart onboarding / plan mode (dev);
   POST /auth/onboarding/reset (?full=1 → back to the door).]**
2. **The brain loop** — server-side: coverage-requirement spine + depth math +
   branching; LLM emits `{nodes, edges, question, coverage}` deltas per answer,
   streamed to the client. Bottom widget (next/back, MC + open-ended).
3. **Live weave** — nodes/edges animate in as the agent answers; camera eases to
   the active cluster; completeness bar (can rise via branching).
4. **The cube** — floating agent, pointer beam, speech-bubble narration, park
   bottom-left; mic (Moonshine) on open-ended questions.
5. **Compile + boot** — approve → compile graph → `.work` + vault docs → punch-list
   materialization (amber needs-you nodes with inline actions). Curated vault
   catalog + LLM fallback.
6. **Persistence + parity** — graph persists as the live body view; the SAME
   flow available in the Workbooks dashboard (shared endpoints, like the billing).

Fallback throughout: no AI key → the existing form quiz.

---

## 9 · Open / to-decide-later

- Exact base coverage requirements + their depth thresholds (the seed rubric).
- The compile mapping (free-form graph → `.work`) — the LLM-assisted "Inform 6"
  step; how deterministic vs generative.
- Dashboard parity: how much of the D3 experience ports vs a lighter dashboard
  variant.
- Voice (beyond mic STT) — deferred; "no voice here yet."
