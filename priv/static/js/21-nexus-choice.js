// ── NEXUS CHOICE — "where does your autopoet live?" (onboarding) ────────────
// One radio-card accordion, three lanes: the nexus you already have (live from
// the account) · create one on Workbooks Cloud (inline machine setup — custom
// tier picker, credit chips, top-up toggle; no native selects) · run locally
// on your own key. Selecting expands the lane; one continue gates on powered.
function showPower() {
  if (typeof _slideCleanup !== "undefined" && _slideCleanup) { _slideCleanup(); _slideCleanup = null; }
  document.getElementById("obslides").style.display = "none";
  document.querySelector("#onboard .obinner").style.display = "none";
  const s = document.getElementById("obsteps");
  s.style.display = "flex";
  s.style.maxWidth = "680px";
  s.innerHTML = `
    <div class="obword" style="font-size:24px">where does your autopoet live?</div>
    <p class="obtext" style="margin:0">Connect the nexus you already have, create one on Workbooks
      Cloud, or run locally on your own AI key.</p>
    <div class="nx-stack" id="nx-stack"></div>
    <div class="nx-foot">
      <span id="nx-status" class="nx-status"></span>
      <button class="obstepgo" id="nx-continue" disabled style="opacity:.4">continue →</button>
    </div>`;

  const stack = document.getElementById("nx-stack");
  const cont = document.getElementById("nx-continue");
  const setPowered = (ok, msg) => {
    document.getElementById("nx-status").innerHTML = ok ? `<i data-lucide="check"></i> ${msg}` : msg;
    cont.disabled = !ok; cont.style.opacity = ok ? "1" : ".4";
    refreshIcons();
  };
  cont.onclick = () => { if (!cont.disabled) showPlanMode(); };

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
    lane("cloud", "cloud", "recommended", "Workbooks Cloud", "from $12/mo",
      `<div id="nx-cloud-setup">loading…</div>`) +
    lane("local", "laptop", "", "Bring your own AI", "local · free",
      `<p class="nx-line">Your own OpenRouter key — any model, on your credits. No machine; this desktop does the work.</p>
       <div class="nx-row"><input id="nx-orkey" class="obinput" placeholder="sk-or-…" spellcheck="false">
       <button class="obstepgo" id="nx-uselocal">use my key →</button></div>`);

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
          <span class="nx-go">connect →</span>
        </button>`).join("")));
    stack.querySelectorAll(".nx-pick").forEach(b => b.onclick = () => {
      stack.querySelectorAll(".nx-pick").forEach(x => x.classList.toggle("sel", x === b));
      setPowered(true, `connected to <b>${b.querySelector(".nx-pick-name").textContent.trim()}</b>`);
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

  document.getElementById("nx-uselocal").onclick = async () => {
    const inp = document.getElementById("nx-orkey"), k = inp.value.trim();
    if (!k) { inp.focus(); return; }
    const r = await authedPost("/power/openrouter", k);
    setPowered(r.ok, r.ok ? "local AI connected" : "couldn't save that key — try again");
  };

  // already powered (returning)? say so, keep the choice open
  fetch("/power/status").then(r => r.json()).then(p => {
    if (p.powered) setPowered(true, p.openrouter ? "local AI connected" : "Workbooks Cloud connected");
  }).catch(() => {});

  // ── the cloud lane: machine setup, custom components only ─────────────────
  let cloudMounted = false;
  async function mountCloudSetup() {
    if (cloudMounted) return;
    cloudMounted = true;
    const host = document.getElementById("nx-cloud-setup");
    let tiers = [];
    try { tiers = (await (await fetch("/power/cloud/tiers")).json()).tiers || []; } catch (_) {}
    if (!tiers.length) tiers = [{ id: "solo", name: "Solo", price: 20, ram_mb: 512, storage_gb: 10 }];
    const ram = t => t.ram_mb >= 1024 ? (t.ram_mb / 1024) + "GB" : t.ram_mb + "MB";

    host.innerHTML = `
      <p class="nx-line">Your own machine + AI credits, on one card. Change any of it later.</p>
      <div class="nx-lbl">machine</div>
      <div class="nx-tiers">${tiers.map((t, i) => `
        <button class="nx-tier ${i === 0 ? "sel" : ""}" data-id="${t.id}">
          <b>${t.name}</b><span class="nx-price">$${t.price}<i>/mo</i></span>
          <span class="nx-spec">${ram(t)} · ${t.storage_gb}GB</span>
        </button>`).join("")}</div>
      <div class="nx-lbl">initial AI credits</div>
      <div class="nx-chipsrow" id="nx-credits">${[0, 5, 10, 25, 50].map(v => `
        <button class="nx-chipbtn ${v === 10 ? "sel" : ""}" data-v="${v}">${v ? "$" + v : "none"}</button>`).join("")}
      </div>
      <label class="nx-toggle"><span class="nx-switch" id="nx-ato"><i></i></span>
        <span>auto-top-up — when credits fall below
          $<input id="nx-ato-th" class="nx-mini" value="5"> add
          $<input id="nx-ato-amt" class="nx-mini" value="20"></span></label>
      <button class="obstepgo" id="nx-pay" style="align-self:flex-start;margin-top:6px">continue to payment →</button>
      <div class="nx-status" id="nx-paystatus"></div>`;

    const sel = (q, cb) => host.querySelectorAll(q).forEach(b => b.onclick = () => {
      host.querySelectorAll(q).forEach(x => x.classList.toggle("sel", x === b)); cb && cb(b);
    });
    sel(".nx-tier"); sel(".nx-chipbtn");
    const ato = host.querySelector("#nx-ato");
    ato.onclick = () => ato.classList.toggle("on");

    host.querySelector("#nx-pay").onclick = async () => {
      const tier = host.querySelector(".nx-tier.sel").dataset.id;
      const credits = +host.querySelector(".nx-chipbtn.sel").dataset.v;
      const st = m => host.querySelector("#nx-paystatus").textContent = m;
      host.querySelector("#nx-pay").disabled = true;
      st("preparing checkout…");
      if (ato.classList.contains("on")) {
        await authedPost("/power/cloud/autotopup", JSON.stringify({
          enabled: true, threshold: +host.querySelector("#nx-ato-th").value || 5,
          amount: +host.querySelector("#nx-ato-amt").value || 20 })).catch(() => {});
      }
      const r = await authedPost("/power/cloud/checkout", JSON.stringify({ plan: tier, initial_credit: credits }));
      const d = await r.json().catch(() => ({}));
      if (!r.ok || !d.url) { st(d.detail || d.error || "couldn't start checkout"); host.querySelector("#nx-pay").disabled = false; return; }
      openCheckout(d.url, async () => {
        st("confirming…");
        if (await pollPowered(60)) {
          if (credits > 0) await authedPost("/power/cloud/credits", JSON.stringify({ amount: credits })).catch(() => {});
          setPowered(true, "Workbooks Cloud connected");
          st("");
        } else { st("payment not detected yet — finish in the checkout, then retry"); host.querySelector("#nx-pay").disabled = false; }
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
