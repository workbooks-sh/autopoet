// ── ONBOARDING STEP 1 · COMPUTE — adaptive, prefetch-driven ─────────────────
// Three layouts from ONE entry (showPower): a returning user with a nexus gets
// a single confirmation screen; a new user gets the two-lane picker (cloud
// first, tiers pre-mounted); offline gets the local lane. The status+tiers
// prefetch fires at sign-in success and showSlides (js/18) so this screen
// paints instantly — no pop-in, nothing inserted above rendered content.
// Lane/tier/offline renderers live in js/23-nexus-lanes.js.

function firePowerPrefetch() {
  window._powerPrefetch = Promise.all([
    fetch("/power/status").then(r => r.json()),
    fetch("/power/cloud/tiers").then(r => r.json())
  ]).catch(() => null);
  return window._powerPrefetch;
}

// resolves [status, tiersResp] — or null after 4s / offline. Never rejects.
function powerPrefetch() {
  const live = window._powerPrefetch || firePowerPrefetch();
  return Promise.race([live, new Promise(res => setTimeout(() => res(null), 4000))])
    .then(v => {
      if (v && v[0]) {
        try {
          localStorage.setItem("power.status.v1",
            JSON.stringify({ ts: Date.now(), status: v[0], tiers: (v[1] && v[1].tiers) || [] }));
        } catch (_) {}
      }
      return v || null;
    })
    .catch(() => null);
}

// last good status (optimistic paint while the live fetch reconciles)
function powerCachedStatus() {
  try {
    const c = JSON.parse(localStorage.getItem("power.status.v1"));
    return c && c.status ? c : null;
  } catch (_) { return null; }
}

async function showPower() {
  if (typeof _slideCleanup !== "undefined" && _slideCleanup) { _slideCleanup(); _slideCleanup = null; }
  document.getElementById("obslides").style.display = "none";
  document.querySelector("#onboard .obinner").style.display = "none";
  const s = document.getElementById("obsteps");
  s.style.display = "flex";
  s.style.maxWidth = "680px";
  s.innerHTML = `
    <div class="nx-step" id="nx-chip">step 1 of 2 · compute</div>
    <div class="obword" id="nx-head" style="font-size:24px">where does your autopoet live?</div>
    <p class="obtext" id="nx-line" style="margin:0">pick where it runs. how it thinks is next.</p>
    <div class="nx-stack" id="nx-stack"></div>
    <div class="nx-foot">
      <span id="nx-status" class="nx-status"></span>
      <button class="obstepgo" id="nx-continue" disabled style="opacity:.4">next: how it thinks →</button>
    </div>`;

  const el = id => document.getElementById(id);
  const ctx = { stack: el("nx-stack"), cont: el("nx-continue"),
    chip: el("nx-chip"), head: el("nx-head"), line: el("nx-line"), choice: null };
  ctx.setChosen = (c, msg) => {
    ctx.choice = c;
    el("nx-status").innerHTML = `<i data-lucide="check"></i> ${msg}`;
    ctx.cont.disabled = false; ctx.cont.style.opacity = "1";
    refreshIcons();
  };

  const live = powerPrefetch();
  // already resolved? paint the final layout in one shot — the fast path
  const first = await Promise.race([live, Promise.resolve("__slow")]);
  if (first !== "__slow") return nxRender(ctx, first);

  // slow path: optimistic paint from the cache, else a fixed-height ghost —
  // either is REPLACED IN PLACE when the live fetch lands (no layout jump)
  const cached = powerCachedStatus();
  if (cached) {
    nxRenderStatus(ctx, cached.status, cached.tiers || []);
    el("nx-status").innerHTML = `<i class="nx-chip">checking…</i>`;
  } else {
    nxSkeleton(ctx);
  }
  const v = await live;
  if (v && v[0]) {                        // live truth reconciles the paint —
    if (!ctx.choice) nxRender(ctx, v);    // unless the user already picked
    return;
  }
  if (!cached) return nxOffline(ctx);
  if (!ctx.choice) el("nx-status").innerHTML = `<i class="nx-chip">offline — showing last known</i>`;
}

function nxRender(ctx, v) {
  if (!v || !v[0]) return nxOffline(ctx);
  nxRenderStatus(ctx, v[0], (v[1] && v[1].tiers) || []);
}

function nxRenderStatus(ctx, status, tiers) {
  const list = (status && status.nexuses) || [];
  if (list.length || (status && status.subscription)) nxConfirm(ctx, status, tiers);
  else nxLanes(ctx, tiers);
}

// ── HAS NEXUS — one confirmation screen replaces both steps ────────────────
function nxConfirm(ctx, status, tiers) {
  ctx.chip.textContent = "power · already set";
  ctx.head.textContent = "your autopoet already has a home";
  let list = ((status && status.nexuses) || []).slice();
  const ts = n => Date.parse(n.created_at || n.inserted_at || n.updated_at || "") || 0;
  if (list.some(n => ts(n))) list.sort((a, b) => ts(b) - ts(a)); else list.reverse();
  if (!list.length) {
    const plan = status.subscription && (status.subscription.plan || status.subscription.tier);
    list = [{ id: "cloud", name: plan ? plan + " machine" : "your cloud machine", plan: plan }];
  }
  const name = n => `${n.icon || "◈"} ${n.name || n.id}`;
  ctx.line.textContent = `runs on ${name(list[0])} — AI through the gateway. nothing to buy.`;

  ctx.stack.innerHTML = `
    <div class="nx-picks">${list.map((n, i) => `
      <button class="nx-pick ${i === 0 ? "sel" : ""}" data-id="${n.id}">
        <span class="nx-pick-name">${name(n)}</span>
        <span class="nx-chips">${["plan", "region", "state"].map(k => n[k] ? `<i class="nx-chip">${n[k]}</i>` : "").join("")}</span>
        <span class="nx-go">use it →</span>
      </button>`).join("")}</div>
    <div class="nx-quietrow">
      <a href="#" class="nx-quiet" id="nx-q-more">or create another machine → from $12/mo</a>
      <a href="#" class="nx-quiet" id="nx-q-local">run on this desktop instead</a>
      <a href="#" class="nx-quiet" id="nx-q-key">bring your own key</a>
    </div>
    <div id="nx-moretiers"></div>`;

  const pick = n => ctx.setChosen("nexus " + n.id, `runs on <b>${name(n)}</b>`);
  ctx.stack.querySelectorAll(".nx-pick").forEach(b => b.onclick = () => {
    ctx.stack.querySelectorAll(".nx-pick").forEach(x => x.classList.toggle("sel", x === b));
    pick(list.find(n => String(n.id) === b.dataset.id) || list[0]);
  });
  pick(list[0]);                                    // most recent, preselected

  ctx.cont.textContent = "start planning →";
  ctx.cont.onclick = async () => {
    if (ctx.cont.disabled || !ctx.choice) return;
    await authedPost("/power/compute", ctx.choice).catch(() => {});
    showPlanMode();
  };

  const q = id => document.getElementById(id);
  q("nx-q-more").onclick = e => {                   // the tier UI expands inline
    e.preventDefault();
    const host = q("nx-moretiers");
    if (host.childElementCount) { host.innerHTML = ""; return; }
    nxMountTiers(ctx, host, tiers);
    refreshIcons();
  };
  q("nx-q-local").onclick = async e => {
    e.preventDefault();
    await authedPost("/power/compute", "local").catch(() => {});
    showInference("local");
  };
  q("nx-q-key").onclick = e => { e.preventDefault(); showInference("local"); };
  refreshIcons();
}
