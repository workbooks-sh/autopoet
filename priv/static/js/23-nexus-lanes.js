// ── STEP 1 LANE RENDERERS — no-nexus picker, tiers, skeleton, offline ───────
// Companions to showPower (js/21). Everything renders INTO #nx-stack whole —
// nothing is ever inserted above already-rendered content.

function nxLane(id, icon, badge, title, meta, body, open) {
  return `
    <div class="nx-option${open ? " open" : ""}" data-lane="${id}">
      ${badge ? `<span class="nx-badge">${badge}</span>` : ""}
      <button class="nx-head" data-open="${id}">
        <span class="nx-ico"><i data-lucide="${icon}"></i></span>
        <span class="nx-title">${title}</span>
        <span class="nx-meta">${meta}</span>
        <span class="nx-radio"></span>
      </button>
      <div class="nx-body">${body}</div>
    </div>`;
}

function nxWireLanes(ctx) {
  ctx.stack.querySelectorAll(".nx-head").forEach(h => h.onclick = () => {
    ctx.stack.querySelectorAll(".nx-option").forEach(o =>
      o.classList.toggle("open", o.dataset.lane === h.dataset.open));
    refreshIcons();
  });
}

// fixed-height ghost while the prefetch resolves — replaced in place, no jump
function nxSkeleton(ctx) {
  ctx.stack.innerHTML = `
    <div class="nx-option nx-ghost"><span class="nx-ghosttext">checking your cloud…</span></div>`;
}

// ── NO NEXUS — two lanes: cloud first (open, tiers pre-mounted), local below ─
function nxLanes(ctx, tiers) {
  ctx.chip.textContent = "step 1 of 2 · compute";
  ctx.head.textContent = "where does your autopoet live?";
  ctx.line.textContent = "pick where it runs. how it thinks is next.";
  ctx.cont.textContent = "next: how it thinks →";
  ctx.cont.onclick = async () => {
    if (ctx.cont.disabled || !ctx.choice) return;
    await authedPost("/power/compute", ctx.choice).catch(() => {});
    showInference(ctx.choice === "local" ? "local" : "cloud");
  };
  ctx.stack.innerHTML =
    nxLane("cloud", "cloud", "recommended", "a new machine on Workbooks Cloud", "from $12/mo",
      `<div id="nx-cloud-setup"></div>`, true) +
    nxLane("local", "laptop", "", "this desktop", "free",
      `<p class="nx-line">runs while the app is open — your files, your machine. you can move to a
        cloud machine any time.</p>
       <button class="obstepgo alt" id="nx-uselocal">run on this desktop →</button>`, false);
  nxWireLanes(ctx);
  nxMountTiers(ctx, document.getElementById("nx-cloud-setup"), tiers);
  document.getElementById("nx-uselocal").onclick = () =>
    ctx.setChosen("local", "runs on this desktop");
  refreshIcons();
}

// ── OFFLINE — local lane open; cloud collapsed behind a retry ───────────────
function nxOffline(ctx) {
  ctx.chip.textContent = "step 1 of 2 · compute";
  ctx.head.textContent = "where does your autopoet live?";
  ctx.line.textContent = "pick where it runs. how it thinks is next.";
  ctx.cont.textContent = "next: how it thinks →";
  ctx.cont.onclick = async () => {
    if (ctx.cont.disabled || !ctx.choice) return;
    await authedPost("/power/compute", ctx.choice).catch(() => {});
    showInference("local");
  };
  ctx.stack.innerHTML = `
    <p class="nx-line nx-offline">couldn't reach Workbooks Cloud — you can start on this desktop
      and connect later · <a href="#" class="nx-quiet nx-retry">retry</a></p>` +
    nxLane("local", "laptop", "", "this desktop", "free",
      `<p class="nx-line">runs while the app is open — your files, your machine. you can move to a
        cloud machine any time.</p>
       <button class="obstepgo alt" id="nx-uselocal">run on this desktop →</button>`, true) +
    nxLane("cloud", "cloud", "", "a new machine on Workbooks Cloud", "from $12/mo",
      `<p class="nx-line">plans load once the cloud is reachable.
        <a href="#" class="nx-quiet nx-retry">retry</a></p>`, false);
  nxWireLanes(ctx);
  document.getElementById("nx-uselocal").onclick = () =>
    ctx.setChosen("local", "runs on this desktop");
  ctx.stack.querySelectorAll(".nx-retry").forEach(a => a.onclick = e => {
    e.preventDefault(); firePowerPrefetch(); showPower();
  });
  refreshIcons();
}

// ── TIERS — solo + studio only (studio preselected); the rest behind a link ─
function nxMountTiers(ctx, host, allTiers) {
  let tiers = (allTiers || []).slice();
  if (!tiers.length) tiers = [
    { id: "solo", name: "Solo", price: 12, ram_mb: 512, storage_gb: 10 },
    { id: "studio", name: "Studio", price: 29, ram_mb: 2048, storage_gb: 50 }
  ];
  const ram = t => t.ram_mb >= 1024 ? (t.ram_mb / 1024) + "GB" : t.ram_mb + "MB";
  const card = t => `
    <button class="nx-tier ${t.id === "studio" ? "sel" : ""}" data-id="${t.id}">
      <b>${t.name}</b><span class="nx-price">$${t.price}<i>/mo</i></span>
      <span class="nx-spec">${ram(t)} · ${t.storage_gb}GB</span>
    </button>`;
  const two = tiers.filter(t => ["solo", "studio"].includes(t.id));
  const shown = two.length ? two : tiers.slice(0, 2);

  host.innerHTML = `
    <p class="nx-line">your own machine — always on, one flat price, scale by size.</p>
    <div class="nx-lbl">machine</div>
    <div class="nx-tiers" id="nx-tiergrid">${shown.map(card).join("")}</div>
    ${tiers.length > shown.length ?
      `<a href="#" class="nx-quiet" id="nx-moresizes">more sizes → all plans in the dashboard</a>` : ""}
    <button class="obstepgo" id="nx-pay" style="align-self:flex-start;margin-top:6px">continue to payment →</button>
    <div class="nx-status" id="nx-paystatus"></div>`;

  const grid = host.querySelector("#nx-tiergrid");
  const wireSel = () => {
    grid.querySelectorAll(".nx-tier").forEach(b => b.onclick = () =>
      grid.querySelectorAll(".nx-tier").forEach(x => x.classList.toggle("sel", x === b)));
    if (!grid.querySelector(".nx-tier.sel")) grid.querySelector(".nx-tier").classList.add("sel");
  };
  wireSel();
  const more = host.querySelector("#nx-moresizes");
  if (more) more.onclick = e => {                    // the full ladder, inline
    e.preventDefault();
    const sel = grid.querySelector(".nx-tier.sel");
    const keep = sel && sel.dataset.id;
    grid.innerHTML = tiers.map(card).join("");
    grid.querySelectorAll(".nx-tier").forEach(b =>
      b.classList.toggle("sel", b.dataset.id === (keep || "studio")));
    wireSel();
    more.remove();
  };

  host.querySelector("#nx-pay").onclick = async () => {
    const tier = grid.querySelector(".nx-tier.sel").dataset.id;
    const st = m => host.querySelector("#nx-paystatus").textContent = m;
    host.querySelector("#nx-pay").disabled = true;
    st("preparing checkout…");
    const r = await authedPost("/power/cloud/checkout", JSON.stringify({ plan: tier }));
    const d = await r.json().catch(() => ({}));
    if (!r.ok || !d.url) {
      st(d.detail || d.error || "couldn't start checkout");
      host.querySelector("#nx-pay").disabled = false;
      return;
    }
    openCheckout(d.url, async () => {
      st("confirming…");
      if (await pollPowered(60)) {
        ctx.setChosen("cloud-new " + tier, "machine is yours — running on Workbooks Cloud"); st("");
      } else {
        st("payment not detected yet — finish in the checkout, then retry");
        host.querySelector("#nx-pay").disabled = false;
      }
    });
  };
  refreshIcons();
}

// in-app checkout modal (Polar page; open-in-browser fallback)
function openCheckout(url, onClose) {
  document.getElementById("bp-modal")?.remove();
  const m = document.createElement("div");
  m.id = "bp-modal";
  m.innerHTML = `
    <div class="bpm-card">
      <div class="bpm-head"><span>Workbooks Cloud checkout</span>
        <span><a href="#" id="bpm-ext">open in browser ↗</a> · <button id="bpm-x">✕</button></span></div>
      <iframe id="bpm-frame" src="${url}" allow="payment"></iframe>
    </div>`;
  document.body.appendChild(m);
  document.getElementById("bpm-ext").onclick = (e) => { e.preventDefault(); authedPost("/power/cloud/openurl", url).catch(() => {}); window.open(url, "_blank"); };
  document.getElementById("bpm-x").onclick = () => { m.remove(); onClose && onClose(); };
}

async function pollPowered(tries) {
  for (let i = 0; i < tries; i++) {
    try { const p = await (await fetch("/power/status")).json(); if (p.powered) return true; } catch (_) {}
    await new Promise(r => setTimeout(r, 2500));
  }
  return false;
}
