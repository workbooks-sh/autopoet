# The Lifecycle Plan — onboarding, integrations, and many projects in one autopoet

Strategy doc (2026-07-05, post-48h-op). The question isn't "how do we build an onboarding
wizard" — it's *what are the lifetimes we're serving, and which surface owns each stage.*
Two interleaved lifetimes: the USER's and each PROJECT's. Get the attribution right and
every feature has an obvious home; get it wrong and everything becomes another modal.

---

## 1 · The architectural spine: ONE organism, MANY project workspaces

The 48h op ran a second autopoet via env-var hackery (`venture-home/`). That was the wrong
shape, and the owner's phrasing names the right one: projects live **within the same
autopoet nexus**.

- **One autopoet**: one brain, one vault relationship with its human, one heartbeat, one
  guide/skills library (knowledge is shared — the fund's honesty discipline should benefit
  the e-commerce project for free), one Treasury (with per-project envelopes).
- **A PROJECT is a workspace**: a declared subtree of the body (`ventures/citeflows/`,
  `funds/aether/`) — exactly the workbooks workspace primitive. Each project owns:
  * a **charter** (human-ratified constitution, lives in the vault under the project path)
  * a **desk** (its cadenced work loop — a supervised GenServer keyed by workspace id;
    the Desk/Venture modules become ONE parameterized runtime, archetypes differ by
    charter + toolset, not by module)
  * a **budget envelope** (Treasury sub-ledger: LLM/day, ad spend, purchases)
  * **integration grants** (which platform connections this project may use, and how far)
  * an **index.work dashboard** (the node you click in the graph: status, links, metrics,
    latest proposals)
- **Creation is conversational**: "make me an e-commerce thing" → the agent runs
  project-genesis (research → plan → integration checklist → charter PROPOSAL). Accepting
  the charter births the workspace. No wizard for new projects — the wizard instinct was
  wrong. Conversation in, artifacts out, acceptance as the birth certificate.
- **Death is chartered too**: kill criteria are already in every charter; a killed project's
  workspace is archived (subtree moved to `archive/`), its grants revoked, its envelope
  returned. The graph shows the tombstone; the postmortem stays readable.

## 2 · Self-serve identity — the AgentMail keystone

An agent with its own inbox can complete most signups alone: it demonstrably read and
processed its own Cloudflare verification email. Generalize into a capability:
`SelfServe.signup(service, inbox)` — form-fill via the browser lane, email-verify loop via
AgentMail, credentials into the project's grant store, one line in the audit log. Bot-walls
and CAPTCHAs downgrade the item to a `needs-human` card (honest fallback, no thrashing).
Paid signups additionally pass the Treasury envelope. Rule of thumb the checklist encodes:
*if it needs an inbox, the agent does it; if it needs a wallet or a phone, the human does.*

## 3 · What the 48h op taught that this plan encodes

1. Every major friction was connection-shaped → Stages A/B kill them before the run.
2. Rejections must compound → standing-notes per project, injected into prompts.
3. Brains harvest names from whatever identifier is nearest → canonical name/site injected
   verbatim from ratified docs, never from labels or URLs.
4. The vault-as-constitution works: amendments (hands-off mandate) self-integrated.
5. Live probes at connect time beat any amount of mid-run debugging.
6. Honest ledgers (sleep minutes don't count) keep every later number trustworthy.

## 4 · Sequencing (each stage shippable + testable alone)

1. **The spine**: workspace-per-project inside one autopoet (registry of desks keyed by
   workspace; Desk/Venture merged into one parameterized runtime; project = subtree +
   charter + envelope + grants). Migrate fund/ + venture/ into it.
2. **Genesis-as-conversation**: "new project" → plan → typed checklist → charter proposal
   (checklist derivation + resolver + connection-request proposal type).
3. **Surfaces**: notifications carry connection requests; graph mounts project dashboards +
   preview nodes; Connections page becomes the grant matrix; featured-six reorder.
4. **Self-serve lane**: SelfServe.signup with the AgentMail verify loop + browser form-fill.
5. **Purchases**: registrar lane (Porkbun/Name.com API — CF Registrar can't register) and
   Shopify (custom-app token first) behind Treasury envelopes.

Open questions for the owner:
- One heartbeat scheduling all desks vs per-desk timers (current)? (Proposal: per-desk, one
  supervisor — proven; revisit only if desks multiply past ~10.)
- Should platform connections auto-grant to new projects by default, or explicit-grant-only?
  (Proposal: explicit, with a "grant all basics" one-tap during genesis review.)
- Notification pressure: batch connection-requests into the genesis checklist where
  possible; mid-run requests rate-limited per project per day?

---

## 5 · LOCKED DECISIONS (owner grill, 2026-07-05)

1. **Project creation**: conversational (chat/voice with the autopoet) — genesis proposals
   come back; UI is where you review, not where you create.
2. **Grants**: explicit at genesis review; nothing usable until toggled; "grant all
   basics" one-tap allowed.
3. **Self-serve signups**: FREE services fully autonomous (checklist approval covers it;
   AgentMail inbox does the verify loop). Paid/KYC always a needs-human card.
4. **Mid-run connection requests**: BATCHED DIGEST — collect silently, reviewed when the
   owner opens the app. Zero interruption beats fast unblocking. No notification pings.
5. **Review tiers**: Claude (the operator-agent) reviews routine proposals (content,
   small builds, connection requests) under standing rules; charters, money, identity,
   and anything irreversible always reach the owner's digest.
6. **One organism confirmed**: the fund is a project-workspace like everything else —
   archetypes differ by charter + toolset, never by separate apps/instances.
7. **CiteFlows: ARCHIVE.** Completed experiment (live site + waitlist stay up as
   artifacts); the first project on the new spine starts fresh.
8. **ONBOARDING RESTRUCTURED — the big one**:
   * Onboarding is a **deterministic state machine** (forms) — **no LLM tokens spent
     before the app**. LLM spend starts in-app, where the agent does real work.
   * **NO connections screen in onboarding.** The featured-six-tiles idea is dead as an
     onboarding step; ALL connections defer to in-app, post-plan — the agent asks for
     exactly what its plan needs (typed checklist + digest), which is when the user can
     see WHY each connection matters.
   The typed checklist (the genesis proposal's second page — the ONLY place
   connections are introduced):
   | type | meaning | resolution |
   |------|---------|-----------|
   | `connected` | wallet already covers it | scope toggle: grant this project |
   | `self-serve` | agent signs up ITSELF (AgentMail inbox verify loop) | autonomous if free; logged, revocable |
   | `needs-human` | payment, phone-verify, bot-wall | card: exact reason + deep-link |
   | `suggested` | Composio catalog match for the plan | one-click connect |

   * Onboarding contains: profile quiz (exists) + **payment/tokens** (you fund the agent
     — the existing cloud credits/Polar loop) + a light deterministic "what tools do you
     live in" questionnaire (feeds later suggestions, no keys collected) + the
     **Workbooks Cloud pitch**: what the platform ships built-in — Composio integration
     library, a phone number, and **email as a built-in (white-labeled AgentMail)**:
     every agent gets its own inbox out of the box, provisioned from the platform's
     AgentMail org — the user never sees an AgentMail key.
9. Sequencing unchanged (spine → genesis → surfaces → self-serve → purchases) except:
   the surfaces pass now REMOVES connection tiles from onboarding rather than adding
   them, and adds the payment/tokens step; grant matrix + checklist + digest are the
   only connection surfaces, all in-app.

---

## 6 · EXECUTED (2026-07-05, goal-hook)

- **Spine** (§1): Autopoet.Projects + Autopoet.Desks + parameterized Venture — many
  projects, one organism. spine_test.
- **Full pipeline** (proven e2e, in `mix eval`): pipeline_eval — ctl → conversational
  birth → genesis → typed integration checklist (required charter section) → digest →
  accept → identity → logo → build (JSON-LD + waitlist) → deploy → DASHBOARD node in the
  graph → archive. All production machinery, seams for LLM/search/deploy.
- **CLI control** of a running app AND the packaged prod release: Control plug +
  autopoetctl gain projects/new/status/archive/desk-start/desk-stop/digest. Live smoke
  green against `mix run` AND `_build/prod/rel/autopoet/bin/autopoet` (one boot fix:
  WB_SESSION_SECRET required on a release — added to .env).
- **Self-serve** (§2): Autopoet.SelfServe — the AgentMail verify loop generalized
  (verified / needs-human on bot-wall / no_mail). lanes_eval.
- **Purchase lanes** (§4): Autopoet.Registrar (Porkbun, Treasury-gated money verb) +
  Autopoet.Shopify (custom-app token, gated writes). Both skip-clean. lanes_eval.
- **Featured six**: Connections reordered — google/cloudflare/github/polar/meta/agentmail
  front; openrouter dropped; alpaca/shopify drawer. lanes_eval.
- Full suite 136 + doctest, 0 failures.
- REMAINING (next round, not blocking): desktop UI rendering of the graph
  dashboard/preview/digest (the DATA + nodes exist; the frontend views consume them);
  wiring SelfServe/Registrar/Shopify into the genesis checklist-resolver so `self-serve`
  items auto-execute and `needs-human` items render cards.
