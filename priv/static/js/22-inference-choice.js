// ── ONBOARDING STEP 2 · INFERENCE — "how does it think?" ────────────────────
// Separate from compute (step 1, js/21): this step picks the AI. Workbooks AI
// (credits through the gateway — lots of models, one balance, auto-top-up) or
// your own OpenRouter key. Continue → interactive plan mode.
function showInference() {
  const s = document.getElementById("obsteps");
  s.style.display = "flex";
  s.style.maxWidth = "680px";
  s.innerHTML = `
    <div class="nx-step">step 2 of 2 · inference</div>
    <div class="obword" style="font-size:24px">how does it think?</div>
    <p class="obtext" style="margin:0">Pick its AI. Compute and AI are separate — any mix works.</p>
    <div class="nx-stack" id="inf-stack"></div>
    <div class="nx-foot">
      <button class="obstepgo alt" id="inf-back">← back</button>
      <span id="inf-status" class="nx-status"></span>
      <button class="obstepgo" id="inf-continue" disabled style="opacity:.4">continue →</button>
    </div>`;

  const stack = document.getElementById("inf-stack");
  const cont = document.getElementById("inf-continue");
  document.getElementById("inf-back").onclick = () => showPower();

  const setPowered = (ok, msg) => {
    document.getElementById("inf-status").innerHTML = ok ? `<i data-lucide="check"></i> ${msg}` : msg;
    cont.disabled = !ok; cont.style.opacity = ok ? "1" : ".4";
    refreshIcons();
  };
  cont.onclick = () => { if (!cont.disabled) showPlanMode(); };

  stack.innerHTML = `
    <div class="nx-option" data-lane="wai">
      <span class="nx-badge">recommended</span>
      <button class="nx-head" data-open="wai">
        <span class="nx-ico"><i data-lucide="sparkles"></i></span>
        <span class="nx-title">Workbooks AI</span>
        <span class="nx-meta">many models · one balance</span>
        <span class="nx-radio"></span>
      </button>
      <div class="nx-body">
        <p class="nx-line">AI credits through the gateway — frontier + open models at one price,
          no keys to manage. Same card as your machine.</p>
        <div class="nx-lbl">starting credits</div>
        <div class="nx-chipsrow" id="inf-credits">${[5, 10, 25, 50].map(v => `
          <button class="nx-chipbtn ${v === 10 ? "sel" : ""}" data-v="${v}">$${v}</button>`).join("")}
        </div>
        <label class="nx-toggle"><span class="nx-switch" id="inf-ato"><i></i></span>
          <span>auto-top-up — when credits fall below
            $<input id="inf-ato-th" class="nx-mini" value="5"> add
            $<input id="inf-ato-amt" class="nx-mini" value="20"></span></label>
        <button class="obstepgo" id="inf-buy" style="align-self:flex-start;margin-top:6px">add credits →</button>
        <div class="nx-status" id="inf-buystatus"></div>
      </div>
    </div>
    <div class="nx-option" data-lane="key">
      <button class="nx-head" data-open="key">
        <span class="nx-ico"><i data-lucide="key-round"></i></span>
        <span class="nx-title">Bring your own key</span>
        <span class="nx-meta">OpenRouter · your credits</span>
        <span class="nx-radio"></span>
      </button>
      <div class="nx-body">
        <p class="nx-line">Any model OpenRouter serves, billed to your own account.</p>
        <div class="nx-row"><input id="inf-orkey" class="obinput" placeholder="sk-or-…" spellcheck="false">
        <button class="obstepgo" id="inf-usekey">use my key →</button></div>
      </div>
    </div>`;

  stack.querySelectorAll(".nx-head").forEach(h => h.onclick = () => {
    stack.querySelectorAll(".nx-option").forEach(o =>
      o.classList.toggle("open", o.dataset.lane === h.dataset.open));
    refreshIcons();
  });

  const sel = q => stack.querySelectorAll(q).forEach(b => b.onclick = () =>
    stack.querySelectorAll(q).forEach(x => x.classList.toggle("sel", x === b)));
  sel(".nx-chipbtn");
  const ato = document.getElementById("inf-ato");
  ato.onclick = () => ato.classList.toggle("on");

  // Workbooks AI: save the top-up preference, buy the starting credits
  document.getElementById("inf-buy").onclick = async () => {
    const amount = +stack.querySelector(".nx-chipbtn.sel").dataset.v;
    const st = m => document.getElementById("inf-buystatus").textContent = m;
    document.getElementById("inf-buy").disabled = true;
    st("preparing checkout…");
    if (ato.classList.contains("on")) {
      await authedPost("/power/cloud/autotopup", JSON.stringify({
        enabled: true, threshold: +document.getElementById("inf-ato-th").value || 5,
        amount: +document.getElementById("inf-ato-amt").value || 20 })).catch(() => {});
    }
    const r = await authedPost("/power/cloud/credits", JSON.stringify({ amount }));
    const d = await r.json().catch(() => ({}));
    if (r.ok && d.url) {
      openCheckout(d.url, () => { setPowered(true, `Workbooks AI — $${amount} added`); st(""); });
    } else if (r.ok) {
      setPowered(true, `Workbooks AI — $${amount} added`); st("");
    } else {
      st(d.detail || d.error || "couldn't start the credit purchase");
      document.getElementById("inf-buy").disabled = false;
    }
  };

  // own key
  document.getElementById("inf-usekey").onclick = async () => {
    const inp = document.getElementById("inf-orkey"), k = inp.value.trim();
    if (!k) { inp.focus(); return; }
    const r = await authedPost("/power/openrouter", k);
    setPowered(r.ok, r.ok ? "your key is in — any OpenRouter model" : "couldn't save that key — try again");
  };

  // already thinking? (returning user, machine with gateway AI, key on disk)
  fetch("/power/status").then(r => r.json()).then(p => {
    if (p.inference) setPowered(true, p.openrouter ? "your key is connected" : "Workbooks AI is live");
  }).catch(() => {});

  refreshIcons();
}
