// ── BEHAVIOR LAB — dev panel over the LIVE stage (plan mode's 🎛, or settings) ──
// Attaches to whatever verbs object owns the stage (plan mode passes its own),
// so everything runs on the production performer: voice switching via
// verbs.setVoice (design personas / pinned clones), behavior sliders, fire
// buttons, live energy meter. Behaviors fire on speech structure through the
// puppet verbs — nothing re-implemented.
window.BehaviorLab = (() => {
  let verbs = null, panel = null, P = {}, loops = [], attn = "you", traits = null;

  const fromTraits = t => ({
    etP: (t.playfulness ?? .5) * .8, etS: .35 + (t.warmth ?? .5) * .55,
    anP: (t.dominance ?? .5) * .75, anS: .3 + (t.dominance ?? .5) * .6,
    idStill: (t.steadiness ?? .5), idLook: (t.energy ?? .5) * .8,
    idTilt: (t.playfulness ?? .5) * .6, idBlink: .3 + (1 - (t.energy ?? .5)) * .4,
    atRate: .2 + (t.energy ?? .5) * .5,
    tmAmt: (t.energy ?? .5) * .5 + (t.expanse ?? .5) * .4,
    tmSway: (t.playfulness ?? .5), tmBob: (t.energy ?? .5)
  });
  const SLIDERS = [["etP", "end-tilt p"], ["etS", "end-tilt strength"], ["anP", "nod p"], ["anS", "nod strength"],
    ["idStill", "idle: still"], ["idLook", "idle: look"], ["idTilt", "idle: tilt"], ["idBlink", "idle: blink"],
    ["atRate", "attention rate"], ["tmAmt", "talk amount"], ["tmSway", "talk sway"], ["tmBob", "talk bob"]];

  function attach(v) { verbs = v; }

  async function toggle() {
    if (panel) return close();
    if (!verbs) { window.toast && toast("open plan mode first — the lab rides its stage"); return; }
    if (!traits) traits = await (await fetch("/voices/traits.json")).json();
    panel = document.createElement("div");
    panel.id = "blab";
    panel.innerHTML = `
      <div class="bl-hd"><b>behavior lab</b><button id="bl-x">✕</button></div>
      <select id="bl-voice">${Object.keys(traits).sort().map(n => `<option>${n}</option>`).join("")}</select>
      <div class="bl-row">
        <button id="bl-use">use voice</button>
        <button id="bl-take">play take ▸</button>
      </div>
      <div id="bl-sliders"></div>
      <div class="bl-row bl-fire">
        <button data-f="end">sentence end</button><button data-f="nod">affirm</button>
        <button data-f="attn">attention</button><button data-f="wave">wave</button>
      </div>
      <div class="bl-meter"><i id="bl-e"></i></div>
      <div class="bl-note" id="bl-note"></div>`;
    document.body.appendChild(panel);

    const sel = panel.querySelector("#bl-voice");
    const load = name => {
      P = fromTraits(traits[name] || {});
      panel.querySelector("#bl-sliders").innerHTML = SLIDERS.map(([k, lbl]) => `
        <label class="bl-tr"><span>${lbl}</span>
          <input type="range" min="0" max="1" step="0.05" value="${P[k]}" data-k="${k}"></label>`).join("");
      panel.querySelectorAll("input[data-k]").forEach(i => i.oninput = () => P[i.dataset.k] = +i.value);
    };
    sel.onchange = () => load(sel.value);
    load(sel.value);

    panel.querySelector("#bl-x").onclick = close;
    panel.querySelector("#bl-use").onclick = () => {
      const kind = (traits[sel.value] || {}).kind;
      verbs.setVoice(kind === "pinned"
        ? { engine: "qwen-clone", voice: sel.value }      // clones SYNTHESIZE every line
        : { engine: "qwen-design", persona: sel.value });
      const note = panel.querySelector("#bl-note");
      note.textContent = `session voice → ${sel.value} · engine warming…`;
      (function poll() {
        fetch("/voice/tts/qwen/status").then(r => r.text()).then(st => {
          if (!panel) return;
          if (st.trim() === "ready") note.textContent = `session voice → ${sel.value} ✓ ready — replay a line`;
          else setTimeout(poll, 2000);
        }).catch(() => {});
      })();
    };
    panel.querySelector("#bl-take").onclick = () => verbs.playTake(`/voices/take/${sel.value}.wav`);
    panel.querySelectorAll(".bl-fire button").forEach(b => b.onclick = () => fire(b.dataset.f));
    startLoops();
  }

  function fire(what) {
    if (!verbs) return;
    if (what === "end") {
      const s = P.etS, dir = Math.random() < .5 ? -1 : 1;
      verbs.tilt(dir * (7 + s * 12), 650 + s * 400);
      verbs.eyes(false);
      setTimeout(() => verbs && verbs.eyes(true), 480 + s * 380);
    }
    if (what === "nod") verbs.nod(.4 + P.anS * 1.1);
    if (what === "attn") {
      attn = attn === "you" ? "board" : "you";
      const st = document.getElementById("stage").getBoundingClientRect();
      const gb = document.getElementById("vs-graph-bg");
      const b = gb && gb.firstElementChild ? gb.firstElementChild.getBoundingClientRect() : null;
      const p = attn === "board" && b
        ? { x: b.left + b.width / 2, y: b.top + b.height / 2 }
        : { x: st.left + st.width / 2, y: st.top + st.height * .85 };
      verbs.lookAt(p.x, p.y, 2600);
    }
    if (what === "wave") verbs.wave();
  }

  function startLoops() {
    let silentMs = 0, lastBob = 0;
    let rafId = requestAnimationFrame(function tick(now) {
      if (!panel) return;
      const e = verbs.energy();
      const m = panel.querySelector("#bl-e");
      if (m) m.style.width = (e * 100) + "%";
      if (verbs.speaking()) {
        if (e > .07) silentMs = 0; else silentMs += 16;
        if (silentMs > 340 && silentMs < 360 && Math.random() < P.etP) fire("end");
        if (e > .3 && now - lastBob > 420 && Math.random() < P.tmBob * P.tmAmt) { verbs.nod(.25 + P.tmAmt * .3); lastBob = now; }
        if (Math.random() < P.tmSway * P.tmAmt * .012) verbs.tilt((Math.random() * 2 - 1) * 4, 800);
      }
      rafId = requestAnimationFrame(tick);
    });
    loops.push(() => cancelAnimationFrame(rafId));

    const idle = setInterval(() => {
      if (!verbs || verbs.speaking() || !panel) return;
      const w = [["still", P.idStill], ["look", P.idLook], ["tilt", P.idTilt], ["blink", P.idBlink]];
      const total = w.reduce((a, [, x]) => a + x, 0) || 1;
      let r = Math.random() * total, pick = "still";
      for (const [k, x] of w) { r -= x; if (r <= 0) { pick = k; break; } }
      const st = document.getElementById("stage").getBoundingClientRect();
      if (pick === "look") verbs.lookAt(st.left + st.width * (0.2 + Math.random() * .6), st.top + st.height * (0.2 + Math.random() * .4), 1500);
      if (pick === "tilt") verbs.tilt((Math.random() * 2 - 1) * 5, 1100);
      if (pick === "blink") { verbs.eyes(false); setTimeout(() => verbs && verbs.eyes(true), 240); }
    }, 3400);
    loops.push(() => clearInterval(idle));

    const at = setInterval(() => { if (verbs && verbs.speaking() && Math.random() < P.atRate) fire("attn"); }, 3000);
    loops.push(() => clearInterval(at));
  }

  function close() {
    loops.forEach(f => f()); loops = [];
    if (panel) { panel.remove(); panel = null; }
  }

  return { attach, toggle, close };
})();
