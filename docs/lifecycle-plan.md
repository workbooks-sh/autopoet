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

## 2 · The integration lifecycle — three stages, three surfaces

Connections are not an onboarding event; they're a lifetime. Wrong today: everything
mid-run, keys hunted by hand. Right: each stage owned by the surface where it naturally
occurs.

**Stage A — Platform basics (onboarding, once).** The existing desktop Intake stays easy
and gains one screen: the featured six as tiles — **Google, Cloudflare, GitHub, Polar,
Meta, AgentMail** (X/Alpaca/Shopify demoted to the drawer; OpenRouter stays demoted — AI
rides the Workbooks gateway). Every connect runs a **live probe at connect time** and shows
what it sees (account id, zones list, credit balance) — the wrong-account/wrong-scope class
of failure dies here, visibly. These are USER-level connections: the wallet.

**Stage B — Project needs (genesis, per project).** The plan derives a **typed integration
checklist** — the genesis proposal's second page:
| type | meaning | resolution |
|------|---------|-----------|
| `connected` | platform wallet already covers it | scope toggle: grant this project |
| `self-serve` | agent can sign up ITSELF (its AgentMail inbox does the email-verify loop — proven mechanic) | agent executes, logged, revocable |
| `needs-human` | payment, phone-verify, ToS/bot-wall | one card: exact reason + deep-link |
| `suggested` | Composio catalog match for the plan | one-click connect via Composio |
Every item carries its WHY. The checklist is a live `.work` page in the workspace.

**Stage C — Continual (the whole project life).** The owner's key insight: **notifications
are the surface for mid-life connection requests.** When a desk hits a wall ("I could read
competitor reviews if I had the Trustpilot toolkit"), it files a **connection-request
proposal** — a first-class proposal type, same machinery as charters and posts: the WHY,
what it unlocks, the Composio deep-link or a self-serve declaration. It appears in
notifications; the human taps connect/approve/deny; denial with reason lands in the
project's standing notes (rejections must compound — the marketing-notes lesson).

**The grant matrix.** Connections are platform-level; USE is project-level. The Connections
page becomes a matrix: rows = connections, columns = projects, cells = grants with scope
(Cloudflare: citeflows project may touch `citeflows.com` zone only). This is the cage
generalized to integrations — same philosophy as the trading caps.

## 3 · Self-serve identity — the AgentMail keystone

An agent with its own inbox can complete most signups alone: it demonstrably read and
processed its own Cloudflare verification email. Generalize into a capability:
`SelfServe.signup(service, inbox)` — form-fill via the browser lane, email-verify loop via
AgentMail, credentials into the project's grant store, one line in the audit log. Bot-walls
and CAPTCHAs downgrade the item to a `needs-human` card (honest fallback, no thrashing).
Paid signups additionally pass the Treasury envelope. Rule of thumb the checklist encodes:
*if it needs an inbox, the agent does it; if it needs a wallet or a phone, the human does.*

## 4 · The user lifetime — stage → surface attribution

| stage | what happens | owning surface |
|-------|-------------|----------------|
| install/onboard | identity, profile quiz (exists), featured-six tiles + probes | Intake (desktop onboarding) |
| first project | guided genesis — the existing intake ignition IS this | Intake → first charter proposal |
| operator loop | review proposals (charters, posts, connection requests), watch desks | **Notifications** + graph |
| multi-project | "make me a finance one too" → conversational genesis → new workspace | chat/voice + graph |
| oversight | budgets, grants matrix, kill switches | Treasury page + Connections page |
| scale-out | cloud deploy of the same organism (AUTOPOET_TARGET=cloud exists) | later |

And the agent lifetime per project: genesis → identity (domain/email/handles) →
build/operate cadence → measure vs validation numbers → evolve or die by its own kill
criteria. Every stage already has a proven mechanic from the 48h op; what's new is the
spine (workspaces) and the surfaces (notifications, matrix, dashboards).

## 5 · What the 48h op taught that this plan encodes

1. Every major friction was connection-shaped → Stages A/B kill them before the run.
2. Rejections must compound → standing-notes per project, injected into prompts.
3. Brains harvest names from whatever identifier is nearest → canonical name/site injected
   verbatim from ratified docs, never from labels or URLs.
4. The vault-as-constitution works: amendments (hands-off mandate) self-integrated.
5. Live probes at connect time beat any amount of mid-run debugging.
6. Honest ledgers (sleep minutes don't count) keep every later number trustworthy.

## 6 · Sequencing (each stage shippable + testable alone)

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

## 7 · LOCKED DECISIONS (owner grill, 2026-07-05)

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
