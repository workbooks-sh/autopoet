// ── "customize autopoet" editor: fade the graph to just the character + float tools ──
// `onboarding` mode reuses the SAME editor (real 3D cube on the grid) but adds
// voice + personality pickers and a "meet your autopoet" hand-off.
function enterCharacterMode(onboarding) {
  if (charEditMode) return;
  if (!selfCube) { toast("open a workspace to meet your autopoet"); return; }
  if (selfCube.dataset.free === "1") { toast("finish the call first"); return; }
  charEditMode = true;
  document.body.classList.add("char-editing");
  g.transition().duration(350).style("opacity", 0.05);
  selfCube.style.transform = "";               // let the .char-edit CSS transform take over
  selfCube.classList.add("char-edit");
  buildCharTools(onboarding);
}

// the Kokoro onboarding entry: the SAME 3D avatar on the grid, with voice +
// personality added. Called from showPlanMode after the voice warm-up.
async function enterDesignerOnboarding() {
  hideOnboard();
  await ensureSelfCube();
  if (selfCube) selfCube.dataset.free = "0";
  enterCharacterMode(true);
}

// the actual Kokoro voice files (data/models/kokoro/voices) — the REAL names.
// Kokoro naming: 1st letter = accent (a=US, b=GB, e=ES, f=FR, h=IN, i=IT,
// j=JP, p=BR, z=CN), 2nd = gender. The country flag comes from that prefix.
const AP_VOICES = ["bf_emma", "af_heart", "am_santa"];
const AP_FLAG = { a: "🇺🇸", b: "🇬🇧", e: "🇪🇸", f: "🇫🇷", h: "🇮🇳", i: "🇮🇹", j: "🇯🇵", p: "🇧🇷", z: "🇨🇳" };
const voiceLabel = id => `${AP_FLAG[id[0]] || "🏳️"} ${id}`;
const AP_PSAMPLE = {
  warm: "Lovely to meet you. Let's build your whole workspace together.",
  direct: "Right. Let's set up your environment and get to work.",
  witty: "Well then. Let's turn your plans into something that actually runs.",
  calm: "Take a breath. We'll set this up one steady step at a time.",
  bold: "Let's go. We're building your entire operation from the ground up."
};
let _apVoice = 0, _apPers = 0, _apPersonalities = null, _apPrevAudio = null;

// preview toggles: a lucide PLAY icon that becomes STOP while sounding; the
// same button click stops playback. `btn` is the <button> to swap the icon in.
function apPreview(text, btn) {
  const setIcon = name => { if (btn) { btn.innerHTML = `<i data-lucide="${name}"></i>`; refreshIcons && refreshIcons(); } };
  // if this button is already playing, stop
  if (_apPrevAudio && _apPrevAudio._btn === btn && !_apPrevAudio.paused) {
    try { _apPrevAudio.pause(); } catch (_) {}
    setIcon("play"); return;
  }
  if (_apPrevAudio) { try { _apPrevAudio.pause(); } catch (_) {} document.querySelectorAll(".ct-play").forEach(b => b.innerHTML = `<i data-lucide="play"></i>`); }
  setIcon("loader");
  fetch(`/voice/tts?engine=qwen-clone&voice=${AP_VOICES[_apVoice]}`, {
    method: "POST", headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" }, body: text
  }).then(r => r.ok ? r.arrayBuffer() : null).then(buf => {
    if (!buf) { setIcon("play"); return; }
    const a = new Audio(URL.createObjectURL(new Blob([buf], { type: "audio/wav" })));
    a._btn = btn; _apPrevAudio = a;
    a.onended = () => setIcon("play");
    a.onpause = () => setIcon("play");
    a.onplaying = () => setIcon("square");
    a.play().catch(() => setIcon("play"));
  }).catch(() => setIcon("play"));
}
function exitCharacterMode() {
  if (!charEditMode) return;
  charEditMode = false;
  document.body.classList.remove("char-editing");
  g.transition().duration(350).style("opacity", 1);
  if (selfCube) {
    selfCube.classList.remove("char-edit");
    syncSelfCube();          // snap it straight back to its node — don't wait for a tick
  }
  document.getElementById("char-tools")?.remove();
}
async function buildCharTools(onboarding) {
  document.getElementById("char-tools")?.remove();
  const c = getChar();
  if (onboarding && !_apPersonalities) {
    _apPersonalities = await fetch("/onboard/personalities.json").then(r => r.json()).catch(() => [{ key: "warm", name: "Warm" }]);
  }
  const el = document.createElement("div");
  el.id = "char-tools";
  const pickRow = (label, name, prev) => `
    <div class="ct-row ct-pickrow"><span class="ct-lbl">${label}</span>
      <div class="ct-pick"><button class="ct-arw" data-k="${prev}-" >‹</button>
        <span class="ct-pname" id="ct-${prev}name"></span>
        <button class="ct-play" data-play="${prev}"><i data-lucide="play"></i></button>
        <button class="ct-arw" data-k="${prev}+">›</button></div></div>`;
  el.innerHTML =
    `<div class="ct-title">${onboarding ? "design your autopoet" : "customize your autopoet"}</div>` +
    `<div class="ct-row">` +
      AP_SHAPES.map(s => `<button class="ct-shape ${s.key === c.shape ? "sel" : ""}" data-shape="${s.key}">` +
        `<span class="ct-shape-ic ct-${s.key}"></span>${s.name}</button>`).join("") +
    `</div>` +
    `<div class="ct-row ct-swatches">` +
      AP_PALETTE.map(p => `<button class="ct-swatch ${p.key === c.color ? "sel" : ""}" data-color="${p.key}" ` +
        `title="${p.name}" style="--sw:${p.body}"></button>`).join("") +
    `</div>` +
    (onboarding ? pickRow("voice", "", "voice") + pickRow("personality", "", "pers") : "") +
    (onboarding ? `<button class="ct-done ct-meet">meet your autopoet →</button>`
                : `<button class="ct-done">done</button>`);
  document.body.appendChild(el);
  el.querySelectorAll(".ct-shape").forEach(b => b.onclick = () => {
    setChar({ shape: b.dataset.shape }); applyCharacter();
    el.querySelectorAll(".ct-shape").forEach(x => x.classList.toggle("sel", x === b));
  });
  el.querySelectorAll(".ct-swatch").forEach(b => b.onclick = () => {
    setChar({ color: b.dataset.color }); applyCharacter();
    el.querySelectorAll(".ct-swatch").forEach(x => x.classList.toggle("sel", x === b));
  });

  if (onboarding) {
    const vn = el.querySelector("#ct-voicename"), pn = el.querySelector("#ct-persname");
    const rv = () => vn.textContent = voiceLabel(AP_VOICES[_apVoice]);
    const rp = () => pn.textContent = _apPersonalities[_apPers].name;
    rv(); rp();
    el.querySelectorAll(".ct-arw").forEach(b => b.onclick = () => {
      const k = b.dataset.k;
      if (k === "voice-") _apVoice = (_apVoice + AP_VOICES.length - 1) % AP_VOICES.length;
      if (k === "voice+") _apVoice = (_apVoice + 1) % AP_VOICES.length;
      if (k === "pers-") _apPers = (_apPers + _apPersonalities.length - 1) % _apPersonalities.length;
      if (k === "pers+") _apPers = (_apPers + 1) % _apPersonalities.length;
      rv(); rp();
    });
    el.querySelector('[data-play="voice"]').onclick = e =>
      apPreview("Hello — this is how I'll sound.", e.currentTarget.closest("button"));
    el.querySelector('[data-play="pers"]').onclick = e =>
      apPreview(AP_PSAMPLE[_apPersonalities[_apPers].key] || AP_PSAMPLE.warm, e.currentTarget.closest("button"));
    el.querySelector(".ct-meet").onclick = () => apMeet();
    refreshIcons && refreshIcons();
  } else {
    el.querySelector(".ct-done").onclick = exitCharacterMode;
  }
}

// commit the design → build the character → into the conversation
async function apMeet() {
  const c = getChar();
  const user = (typeof currentUser !== "undefined" && currentUser) || {};
  const picks = {
    voice: AP_VOICES[_apVoice],
    personality: _apPersonalities[_apPers].key,
    color: c.color, shape: c.shape,
    name: user.name && user.name !== "demo" ? user.name : ""
  };
  if (_apPrevAudio) { try { _apPrevAudio.pause(); } catch (_) {} }
  let identity = null;
  try {
    const r = await fetch("/onboard/pick", {
      method: "POST", headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
      body: JSON.stringify(picks)
    });
    if (r.ok) identity = await r.json();
  } catch (_) {}
  exitCharacterMode();
  if (identity && identity.name) showPlanMode(identity);
  else showPower();
}

applyTheme(localStorage.getItem("ap-theme") || "light");
document.getElementById("foot-settings").onclick = e => {
  e.stopPropagation();
  const t = localStorage.getItem("ap-theme") || "light";
  openFootPop(e.currentTarget, `
    <div class="fp-title">appearance</div>
    <div class="fp-seg">
      <button data-theme="light" class="${t === 'light' ? 'sel' : ''}"><i data-lucide="sun"></i>light</button>
      <button data-theme="dark" class="${t === 'dark' ? 'sel' : ''}"><i data-lucide="moon"></i>dark</button>
    </div>
    <div class="fp-sep"></div>
    <button class="fp-item" data-act="customize"><i data-lucide="sparkles"></i>customize autopoet…</button>
    <button class="fp-item" data-act="cloud"><i data-lucide="cloud"></i>workbooks cloud…</button>
    <div class="fp-sep"></div>
    <button class="fp-item" data-act="reonboard"><i data-lucide="rotate-ccw"></i>restart onboarding</button>
    <button class="fp-item" data-act="planmode"><i data-lucide="map"></i>plan mode (dev)</button>
    <button class="fp-item" data-act="blab"><i data-lucide="drama"></i>behavior lab (dev)</button>`);
  document.querySelectorAll("#footpop .fp-seg button").forEach(b => b.onclick = () => {
    applyTheme(b.dataset.theme);
    document.querySelectorAll("#footpop .fp-seg button").forEach(x => x.classList.toggle("sel", x === b));
  });
  document.querySelector('#footpop [data-act="customize"]').onclick = () => { closeFootPop(); enterCharacterMode(); };
  document.querySelector('#footpop [data-act="cloud"]').onclick = () => { closeFootPop(); openCloudPanel(); };
  // DEV loops: restart onboarding (marker + session flag → the flow reruns on
  // reload); plan mode straight in, no reset needed
  document.querySelector('#footpop [data-act="reonboard"]').onclick = () =>
    authedPost("/auth/onboarding/reset").then(() => location.reload());
  document.querySelector('#footpop [data-act="planmode"]').onclick = () => { closeFootPop(); showPlanMode(); };
  document.querySelector('#footpop [data-act="blab"]').onclick = async () => {
    closeFootPop();
    await showPlanMode();
    setTimeout(() => window.BehaviorLab && BehaviorLab.toggle(), 1600);
  };
};

// ── Workbooks Cloud management panel (sign-in status · deploy · machine status) ──────────────────
async function openCloudPanel() {
  document.getElementById("cloudpanel")?.remove();
  const el = document.createElement("div");
  el.id = "cloudpanel";
  el.className = "cpanel-back";
  el.innerHTML = `<div class="cpanel" role="dialog" aria-label="Workbooks Cloud">
      <div class="cpanel-h"><span>Workbooks Cloud</span><button class="cpanel-x" aria-label="Close">×</button></div>
      <div class="cpanel-b" id="cpanel-body"><div class="cpanel-load">loading…</div></div>
    </div>`;
  document.body.appendChild(el);
  el.addEventListener("click", e => { if (e.target === el || e.target.closest(".cpanel-x")) el.remove(); });
  renderCloudPanel();
}

async function renderCloudPanel() {
  const body = document.getElementById("cpanel-body");
  if (!body) return;
  let st = {};
  try { st = await (await fetch("/cloud/status.json")).json(); } catch (_) {}

  if (!st.signed_in) {
    body.innerHTML = `
      <p class="cp-lede">Sign in to run this AutoPoet in the cloud — always-on, reachable from anywhere.</p>
      <button class="cp-btn" id="cp-signin">Sign in to Workbooks Cloud</button>`;
    document.getElementById("cp-signin").onclick = async () => {
      await authedPost("/auth/cloud/open");
      body.innerHTML = `<p class="cp-lede">Finish sign-in in your browser…</p>`;
      pollCloudPanel();
    };
    return;
  }

  const acct = st.account || {};
  const who = acct.email || "your account";
  let raw = {};
  try { raw = await (await fetch("/cloud/machine.json")).json(); } catch (_) {}
  const m = raw.machine || raw;                 // cloud returns {machine, record}
  const state = m.state || m.status || null;
  const region = m.region || (raw.record || {}).region;
  const running = state && /run|start|healthy|live|up/i.test(state);
  const deployed = !!state && !raw.error;

  body.innerHTML = `
    <div class="cp-row"><span class="cp-k">Account</span><span class="cp-v">${who}${acct.role ? ` · ${acct.role}` : ""}</span></div>
    <div class="cp-row"><span class="cp-k">Machine</span><span class="cp-v">${deployed
        ? `<span class="cp-dot ${running ? "on" : "warn"}"></span>${state}${region ? " · " + region : ""}`
        : `<span class="cp-dot off"></span>not deployed`}</span></div>
    <div class="cp-actions">
      ${deployed
        ? `<button class="cp-btn ghost" id="cp-refresh">Refresh status</button>`
        : `<button class="cp-btn" id="cp-deploy">Deploy to cloud</button>`}
      <button class="cp-btn ghost danger" id="cp-disc">Disconnect</button>
    </div>
    <p class="cp-note" id="cp-note"></p>`;

  const deploy = document.getElementById("cp-deploy");
  if (deploy) deploy.onclick = async () => {
    deploy.disabled = true; deploy.textContent = "Deploying…";
    try {
      const r = await authedPost("/cloud/deploy", "");
      if (r.ok) { note("Provisioning your machine — cloning the autopoet image…"); pollMachinePanel(); }
      else { const t = await r.text(); note("Deploy needs setup: " + t.trim()); deploy.disabled = false; deploy.textContent = "Deploy to cloud"; }
    } catch (e) { note("Deploy failed."); deploy.disabled = false; deploy.textContent = "Deploy to cloud"; }
  };
  document.getElementById("cp-refresh")?.addEventListener("click", renderCloudPanel);
  document.getElementById("cp-disc").onclick = async () => {
    await authedPost("/auth/cloud/disconnect");
    renderCloudPanel();
  };
}

function note(t) { const n = document.getElementById("cp-note"); if (n) n.textContent = t; }

let _cpPoll = null;
function pollCloudPanel() {
  clearInterval(_cpPoll); let n = 0;
  _cpPoll = setInterval(async () => {
    n++;
    try { const st = await (await fetch("/cloud/status.json")).json(); if (st.signed_in || n > 90) { clearInterval(_cpPoll); renderCloudPanel(); } } catch (_) {}
  }, 2000);
}
function pollMachinePanel() {
  clearInterval(_cpPoll); let n = 0;
  _cpPoll = setInterval(async () => {
    n++;
    try {
      const raw = await (await fetch("/cloud/machine.json")).json();
      const m = raw.machine || raw;
      const state = m.state || m.status;
      if ((state && /run|start|healthy|live|up/i.test(state)) || n > 60) { clearInterval(_cpPoll); renderCloudPanel(); }
    } catch (_) {}
  }, 3000);
}

// env · integrations (dev-local key/values for now)
const getEnv = () => { try { return JSON.parse(localStorage.getItem("ap-env") || "[]"); } catch (_) { return []; } };
const setEnvRows = rows => localStorage.setItem("ap-env", JSON.stringify(rows));
document.getElementById("foot-env").onclick = e => { e.stopPropagation(); renderEnvPop(e.currentTarget); };
function renderEnvPop(anchor) {
  const rows = getEnv();
  openFootPop(anchor, `
    <div class="fp-title">environment · integrations</div>
    <div class="fp-env" id="fp-env">
      ${rows.map(r => `<div class="fp-envrow"><input class="k" placeholder="KEY" value="${esc(r.k || '')}"><input class="v" placeholder="value" value="${esc(r.v || '')}"><button class="rm">×</button></div>`).join("")}
    </div>
    <button class="fp-envadd" id="fp-envadd">+ variable</button>
    <div class="fp-note">// dev-local for now — wires to runtime config later</div>`);
  const commit = () => setEnvRows([...document.querySelectorAll("#fp-env .fp-envrow")].map(row =>
    ({ k: row.querySelector(".k").value, v: row.querySelector(".v").value })));
  document.querySelectorAll("#fp-env input").forEach(inp => inp.oninput = commit);
  document.querySelectorAll("#fp-env .rm").forEach((b, i) => b.onclick = () => { const rs = getEnv(); rs.splice(i, 1); setEnvRows(rs); renderEnvPop(anchor); });
  document.getElementById("fp-envadd").onclick = () => { commit(); const rs = getEnv(); rs.push({ k: "", v: "" }); setEnvRows(rs); renderEnvPop(anchor); };
}
