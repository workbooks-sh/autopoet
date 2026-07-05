// ── ONBOARDING STEP 1 · COMPUTE — "where does your autopoet live?" ──────────
// Separate from inference (step 2, js/22): this step picks WHERE IT RUNS —
// the nexus you already have · a new machine on Workbooks Cloud (tier cards +
// payment) · this desktop (free). The choice persists via POST /power/compute.
function showPower() {
  if (typeof _slideCleanup !== "undefined" && _slideCleanup) { _slideCleanup(); _slideCleanup = null; }
  document.getElementById("obslides").style.display = "none";
  document.querySelector("#onboard .obinner").style.display = "none";
  const s = document.getElementById("obsteps");
  s.style.display = "flex";
  s.style.maxWidth = "680px";
  s.innerHTML = `
    <div class="nx-step">step 1 of 2 · compute</div>
    <div class="obword" style="font-size:24px">where does your autopoet live?</div>
    <p class="obtext" style="margin:0">Pick where it runs. How it thinks (its AI) is the next step.</p>
    <div class="nx-stack" id="nx-stack"></div>
    <div class="nx-foot">
      <span id="nx-status" class="nx-status"></span>
      <button class="obstepgo" id="nx-continue" disabled style="opacity:.4">next: how it thinks →</button>
    </div>`;

  const stack = document.getElementById("nx-stack");
  const cont = document.getElementById("nx-continue");
  let choice = null;

  const setChosen = (c, msg) => {
    choice = c;
    document.getElementById("nx-status").innerHTML = `<i data-lucide="check"></i> ${msg}`;
    cont.disabled = false; cont.style.opacity = "1";
    refreshIcons();
  };
  cont.onclick = async () => {
    if (cont.disabled || !choice) return;
    await authedPost("/power/compute", choice).catch(() => {});
    showInference();
  };

  const lane = (id, icon, badge, title, meta, body) => `
    <div class="nx-option" data-lane="${id}">
      ${badge ? `<span class="nx-badge">${badge}</span>` : ""}
      <button class="nx-head" data-open="${id}">
        <span class="nx-ico"><i data-lucide="${icon}"></i></span>
        <span class="nx-title">${title}</span>
        <span class="nx-meta">${meta}</span>
        <span class="nx-radio"></span>
      </button>
      <div class="nx-body">${body}</div>
    </div>`;

  stack.innerHTML =
    lane("cloud", "cloud", "recommended", "A new machine on Workbooks Cloud", "from $12/mo",
      `<div id="nx-cloud-setup">loading…</div>`) +
    lane("local", "laptop", "", "This desktop", "free",
      `<p class="nx-line">Runs while the app is open — your files, your machine. You can move to a
        cloud machine any time.</p>
       <button class="obstepgo alt" id="nx-uselocal">run on this desktop →</button>`);

  // the nexuses you ALREADY have lead the stack (zero-cost path)
  fetch("/power/cloud/nexuses").then(r => r.json()).then(d => {
    const list = (d && (d.nexuses || d.items)) || (Array.isArray(d) ? d : []);
    if (!list.length) return;
    stack.insertAdjacentHTML("afterbegin", lane("mine", "server", "your nexus",
      "Use the nexus you already have", `${list.length} running`,
      list.map(n => `
        <button class="nx-pick" data-id="${n.id}">
          <span class="nx-pick-name">${n.icon || "◈"} ${n.name || n.id}</span>
          <span class="nx-chips">${["plan", "region", "state"].map(k => n[k] ? `<i class="nx-chip">${n[k]}</i>` : "").join("")}</span>
          <span class="nx-go">use it →</span>
        </button>`).join("")));
    stack.querySelectorAll(".nx-pick").forEach(b => b.onclick = () => {
      stack.querySelectorAll(".nx-pick").forEach(x => x.classList.toggle("sel", x === b));
      setChosen("nexus " + b.dataset.id, `runs on <b>${b.querySelector(".nx-pick-name").textContent.trim()}</b>`);
    });
    wire();
  }).catch(() => {});

  function wire() {
    stack.querySelectorAll(".nx-head").forEach(h => h.onclick = () => {
      const id = h.dataset.open;
      stack.querySelectorAll(".nx-option").forEach(o =>
        o.classList.toggle("open", o.dataset.lane === id));
      if (id === "cloud") mountCloudSetup();
      refreshIcons();
    });
  }
  wire(); refreshIcons();

  document.getElementById("nx-uselocal").onclick = () =>
    setChosen("local", "runs on this desktop");

  // ── the cloud lane: MACHINE ONLY (credits moved to the inference step) ────
  let cloudMounted = false;
  async function mountCloudSetup() {
    if (cloudMounted) return;
    cloudMounted = true;
    const host = document.getElementById("nx-cloud-setup");
    let tiers = [];
    try { tiers = (await (await fetch("/power/cloud/tiers")).json()).tiers || []; } catch (_) {}
    if (!tiers.length) tiers = [{ id: "solo", name: "Solo", price: 12, ram_mb: 512, storage_gb: 10 }];
    const ram = t => t.ram_mb >= 1024 ? (t.ram_mb / 1024) + "GB" : t.ram_mb + "MB";

    host.innerHTML = `
      <p class="nx-line">Your own machine — always on, one flat price, scale by size.</p>
      <div class="nx-lbl">machine</div>
      <div class="nx-tiers">${tiers.map((t, i) => `
        <button class="nx-tier ${i === 0 ? "sel" : ""}" data-id="${t.id}">
          <b>${t.name}</b><span class="nx-price">$${t.price}<i>/mo</i></span>
          <span class="nx-spec">${ram(t)} · ${t.storage_gb}GB</span>
        </button>`).join("")}</div>
      <button class="obstepgo" id="nx-pay" style="align-self:flex-start;margin-top:6px">continue to payment →</button>
      <div class="nx-status" id="nx-paystatus"></div>`;

    host.querySelectorAll(".nx-tier").forEach(b => b.onclick = () =>
      host.querySelectorAll(".nx-tier").forEach(x => x.classList.toggle("sel", x === b)));

    host.querySelector("#nx-pay").onclick = async () => {
      const tier = host.querySelector(".nx-tier.sel").dataset.id;
      const st = m => host.querySelector("#nx-paystatus").textContent = m;
      host.querySelector("#nx-pay").disabled = true;
      st("preparing checkout…");
      const r = await authedPost("/power/cloud/checkout", JSON.stringify({ plan: tier }));
      const d = await r.json().catch(() => ({}));
      if (!r.ok || !d.url) { st(d.detail || d.error || "couldn't start checkout"); host.querySelector("#nx-pay").disabled = false; return; }
      openCheckout(d.url, async () => {
        st("confirming…");
        if (await pollPowered(60)) { setChosen("cloud-new " + tier, "machine is yours — running on Workbooks Cloud"); st(""); }
        else { st("payment not detected yet — finish in the checkout, then retry"); host.querySelector("#nx-pay").disabled = false; }
      });
    };
    refreshIcons();
  }
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
