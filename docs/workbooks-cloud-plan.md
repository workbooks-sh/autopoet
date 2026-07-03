# Workbooks Cloud — the 6th integration (cloud host + whitelabeled Composio)

The 6th connect card is unlike the other five: it's not OAuth-to-a-third-party,
it's OAuth-to-OUR-cloud. Connecting it (1) moves the user's autopoet off their
laptop onto a **vendored Fly machine**, and (2) turns on **whitelabeled Composio**
so the agent can use any tool in the Composio library under our brand. For this
version it's a deliberately *simple* cloud-management layer — a dashboard for
"your server + your integrations" — NOT the full dogfood cloud app (that
migration is a later option).

## The shape

```
 desktop autopoet ──OAuth──▶ Workbooks Cloud control plane ──org token──▶ Fly Machines API
     (or its cloud twin)         (new small service)        ──org key────▶ Composio API
                                   holds: fly org token,
                                   composio org key,
                                   tenant→app map, dashboard
```

The control plane is the new piece. It is the OAuth **provider** (the user has a
Workbooks Cloud account), the **broker** (it holds the Fly org token + Composio
org key; customers never see either), and the **dashboard** (manage your machine
+ integrations). Everything below is what it does.

## Part A — vendor a Fly machine per user (the "cloud host")

Pattern Fly itself blesses (`one-app-per-user-why`): **one Fly app per customer**,
one org-scoped token held server-side, autopoet image shipped once.

- **Provision on connect** (control-plane broker → `https://api.machines.dev/v1`,
  `Authorization: Bearer <FLY_ORG_TOKEN>`):
  1. `POST /v1/apps` `{app_name: "cust-<id>", org_slug, network: "cust-<id>"}` —
     unique `network` puts each tenant on its own 6PN (can't reach others).
  2. `POST /v1/apps/{app}/volumes` `{name:"data", size_gb:10, encrypted:true}` —
     per-user persistence (also mirror durable state to Tigris/S3; volumes aren't HA).
  3. `POST /v1/apps/{app}/machines` with `config.image =
     registry.fly.io/autopoet:vN`, `guest {shared, 1cpu, 512mb}`,
     `mounts:[{volume, path:/data}]`, `env {NEXUS_TENANT, WB_DATA:/data}`,
     `services` with `autostart:true, autostop:"suspend"`, a `/health` check.
  4. `GET .../machines/{id}/wait?state=started` to confirm.
- **Image**: build once → `registry.fly.io/autopoet:vN` (registry is org-scoped,
  build-once-deploy-many). Use immutable tags (`:v2`, `:sha`), never `:latest`, so
  rollout is controlled/canaryable. Fleet update = broker loops apps, re-POSTs the
  machine config with the new image tag (throttle ~1 req/s/action).
- **Routing**: simplest = expose a service → each customer gets `cust-<id>.fly.dev`.
  Cleaner = one public **router app** matching `*.workbooks…`, look up the tenant's
  app, return a `fly-replay` header → Fly proxy forwards internally (~10ms), keeps
  customer machines off the public internet.
- **Cost lever** (the reselling win): `autostop:"suspend"` + `autostart:true` =
  scale-to-near-zero. Idle customer bills only rootfs + volume storage
  (~$1–2/mo); an active 512MB machine ~$3.32/mo + volume + egress. Compute is
  per-second only while running. Reserved "Machines blocks" ~40% off once the
  baseline is predictable.
- **Broker auth**: one **org-scoped** Fly token (dashboard → Tokens → org token).
  Desktop/dashboard authenticates to OUR API (our own auth), never to Fly.

## Part B — whitelabeled Composio (the "any integration")

Composio (SDK v3 terms): **user** (`user_id`) · **auth config** (`ac_…`, how a
toolkit authenticates) · **connected account** (the user's stored, encrypted
grant). Composio hosts the OAuth and auto-refreshes; tokens never pass through us
or the model. Drive it from Elixir over REST — base
`https://backend.composio.dev/api/v3.1`, header `x-api-key` (org key for
multi-tenant). **Verified working with our key** (200, Gmail toolkit = 61 tools).

- **Whitelabel = custom auth configs.** Per OAuth toolkit we register OUR OWN
  OAuth client (Google, Slack, Notion, …) and `POST /api/v3.1/auth_configs`
  `{toolkit, options:{type:"use_custom_auth", auth_scheme:"OAUTH2", credentials:{
  client_id, client_secret, oauth_redirect_uri}}}` → `ac_…`. Then the consent
  screen shows **our** app name, not "Composio." (Managed auth = Composio's brand;
  only for prototyping.) Full-domain white-label = a thin endpoint on our domain
  that 302-redirects Composio's callback query string through.
- **Connection lifecycle** (per user, per toolkit): `POST
  /api/v3.1/connected_accounts` `{auth_config.id, connection.user_id,
  connection.state.authScheme:"OAUTH2", connection.callback_url}` → returns
  `redirect_url`; user consents; poll `GET /connected_accounts/{id}` until
  `ACTIVE`. (Custom auth configs keep this endpoint valid — the managed-OAuth path
  is being retired to 400.)
- **Execution — MCP is the clean path.** autopoet already speaks MCP, so instead
  of hand-injecting tool schemas: `POST /api/v3/mcp/servers` (which toolkits +
  which `ac_…` + `allowed_tools`) → per-user URL
  `https://backend.composio.dev/v3/mcp/{SERVER_ID}?user_id={USER}` with
  `x-api-key`. The agent's MCP client connects and the tools appear, scoped to
  that user's connected accounts. (REST `tools/execute` is the alternative if we
  want tools in our own LLM loop instead of MCP.)
- **Billing**: tool-CALLS (executions). 20K/mo free, $29→200K, $229→2M; no
  per-user/per-connection fee → resells on execution volume. Org API key +
  Composio "projects" for tenant isolation.

## Two horizons (the honest split)

**Buildable NOW, in the desktop, no cloud service:**
- `Autopoet.Composio` — an Elixir REST client (list toolkits, create a connection
  request, poll status, generate a per-user MCP URL / execute a tool) driven by
  the local `COMPOSIO_API_KEY`. A single-user local autopoet can connect its own
  Gmail/Slack/Notion and use them **today**. Whitelabel (our brand on consent)
  needs a custom auth config per toolkit — additive, per-toolkit.
- This delivers the "connect to any Composio tool" value immediately, decoupled
  from the cloud host.

**Needs the control plane stood up (the real new service):**
- The Workbooks Cloud OAuth provider (users have accounts).
- The Fly broker (org token, per-tenant app/machine/volume provisioning, router,
  image pipeline, fleet updates).
- Multi-tenant Composio (org key, per-tenant `user_id`, custom auth configs, MCP
  URLs per tenant).
- The management dashboard ("your server + your integrations").
- The desktop "Workbooks Cloud" connect card → OAuth → provision → the desktop
  hands off to (or mirrors into) the cloud machine.

## Recommended sequencing

1. **Phase 1 — Composio local capability** (`Autopoet.Composio`): the agent can
   use library tools now, with the key we have. Verifiable immediately. Highest
   value-per-effort; independent of the cloud.
2. **Phase 2 — the connect card + OAuth stub**: add the "Workbooks Cloud" card and
   the OAuth-to-control-plane flow shape (pointing at a to-be-built endpoint), so
   the onboarding is complete and the wiring is ready.
3. **Phase 3 — the control plane** (new service): Fly broker + provisioning +
   dashboard + multi-tenant Composio whitelabel. The big build; scope it as its
   own project. Image pipeline (autopoet → registry.fly.io) is the first brick.
4. **Later option** — fold into the dogfood cloud control plane instead of the
   simple standalone one, once the simple version proves the shape.

## What this makes true

With Parts A+B live, an autopoet on a vendored machine can: run 24/7 without the
laptop, reach any Composio tool as the user (under our brand), take payments
(Polar), publish (Cloudflare), run its own inference (OpenRouter), and manage its
own email (Workspace DWD) — i.e. the "could it build a business on its own" surface
from earlier, now with a place to actually run and a toolbelt to act through.
