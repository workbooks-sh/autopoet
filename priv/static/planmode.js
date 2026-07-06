// ── INTERACTIVE PLAN MODE — a thin driver over VoiceStage.stage({type:"plan"}) ──
// docs/interactive-plan-mode.md. NOTHING re-implemented: the ADOPTED self cube
// (the user's own set autopoet design — same body, same face, same soul as the
// voice call), bean hands, pointAt, the D2 whiteboard, progressive reveal,
// captions — all voice-stage.js, entered without audio. This file only owns the
// seed script + the bottom next/back widget. Phase 2 swaps the script for the
// brain loop (dynamic coverage).
window.PlanMode = (() => {

  let opts, board, widget, tools, formHost = null, running = false, pairing = null, designer = null;
  let SCRIPT = [];

  // the pairing → the performed opening: the character's own greeting + the
  // cover card, then STRAIGHT into the live working session (the brain asks
  // its own first question — no canned lines anywhere). Every word on stage
  // comes from the LLM: the greeting/cover from the pairing officer, the rest
  // from /plan/turn.
  function scriptFromPairing(p) {
    // ONE spoken intro: the greeting, on an EMPTY board — no blank cover slide
    // (owner: don't show a page until it authors real content). The deck stays
    // empty until the brain's first real slide. Then straight to the question.
    return [
      { say: p.greeting, gesture: "wave" },
      { handoff: true }
    ];
  }

  // ── mount: standalone stage (own grid + own cube, SEPARATE from the
  //    dashboard graph), form on the grid, character enters, auto-performs ──
  function start(options) {
    opts = options || {};
    document.body.classList.add("pm-screen");
    // stage mode: ADOPT the real #self-cube (opts.stage.adopt) but WITHOUT the
    // graph world-hooks — it beams into center rather than releasing from a
    // node. ONE component, decoupled from the graph view (which stays hidden).
    const stageOpts = Object.assign({ type: "plan", hold: true }, opts.stage || {});
    delete stageOpts.selfSpot;
    delete stageOpts.hideWorld; delete stageOpts.showWorld; delete stageOpts.resync;
    board = VoiceStage.stage(stageOpts);
    if (!board) { document.body.classList.remove("pm-screen"); return false; }

    // minimal utility cluster — NOT navigation: sound + dev only, bottom-left
    tools = document.createElement("div");
    tools.className = "pm-tools-float";
    tools.innerHTML = `
      <button id="pm-sound" class="pm-ico" title="voice on/off"><i data-lucide="volume-2"></i></button>
      <button id="pm-dev" class="pm-ico" title="voice lab (dev)"><i data-lucide="sliders-horizontal"></i></button>`;
    document.body.appendChild(tools);
    tools.querySelector("#pm-sound").onclick = () => {
      const on = board.setTTS(!board.ttsOn());
      tools.querySelector("#pm-sound").innerHTML = `<i data-lucide="${on ? "volume-2" : "volume-x"}"></i>`;
      opts.refreshIcons && opts.refreshIcons();
    };
    if (window.BehaviorLab) BehaviorLab.attach(board);
    tools.querySelector("#pm-dev").onclick = () => window.BehaviorLab && BehaviorLab.toggle();
    wireCamera();
    opts.refreshIcons && opts.refreshIcons();

    // the cube inherits the owner's set design (squircle default + theme-aware
    // outline) — recompute the character vars in case nothing painted them yet
    if (typeof applyCharacter === "function") { try { applyCharacter(); } catch (_) {} }

    // ANTICIPATE WARM-UP: boot the default voice's model NOW, while the form is
    // being filled, so the greeting only pays a generation (not a model load)
    fetch("/voices/default.json").then(r => r.json()).then(d => {
      const model = d && d.engine === "qwen-clone" ? "base" : "design";
      return fetch("/voice/tts/qwen/boot?model=" + model, { method: "POST",
        headers: { authorization: "Bearer " + TOKEN } });
    }).catch(() => {});

    // PREVIEW MODE (lab "restart in this voice"): a pairing is handed in — skip
    // the form, bring the character straight in on the current default voice.
    if (opts.pairing) { onFiled(opts.pairing); return true; }

    // KOKORO: the DESIGNER lives HERE, on the plan-mode grid with the real cube
    // (never the dashboard) — pick voice/personality/color/shape, then meet.
    if (opts.designer) { showDesigner(); return true; }

    // THE FORM — mounted on the stage grid (white card), not the beige overlay
    formHost = window.Requisition.buildForm(onFiled);
    (document.getElementById("stage") || document.body).appendChild(formHost);
    requestAnimationFrame(() => formHost.classList.add("rq-in"));
    return true;
  }

  // ── the DESIGNER (Kokoro): the real cube presented on the grid + the pickers.
  //    Reuses the character store + voice/personality logic from the editor. ──
  async function showDesigner() {
    board.present();   // reveal the cube centered, face on, so design is live
    if (typeof applyCharacter === "function") try { applyCharacter(); } catch (_) {}
    let [personalities, voices] = await Promise.all([
      fetch("/onboard/personalities.json").then(r => r.json()).catch(() => [{ key: "warm", name: "Warm" }]),
      fetch("/voice/kokoro/voices.json").then(r => r.json()).catch(() => (typeof AP_VOICES !== "undefined" ? AP_VOICES : ["bf_emma"]))
    ]);
    // normalize to {id,label}: server returns objects; the fallback is raw ids
    voices = (voices || []).map(v => typeof v === "string" ? { id: v, label: v } : v);
    if (!voices.length) voices = [{ id: "bf_emma", label: "Refined Mezzo" }];
    const pal = (typeof AP_PALETTE !== "undefined") ? AP_PALETTE : [];
    const shapes = (typeof AP_SHAPES !== "undefined") ? AP_SHAPES : [];
    let vi = 0, pi = 0;

    designer = document.createElement("div");
    designer.className = "pm-designer";
    const pickRow = (label, id) => `
      <div class="pmd-row"><span class="pmd-lbl">${label}</span>
        <div class="pmd-pick"><button class="pmd-arw" data-k="${id}-">‹</button>
          <span class="pmd-name" id="pmd-${id}"></span>
          <button class="pmd-play" data-play="${id}"><i data-lucide="play"></i></button>
          <button class="pmd-arw" data-k="${id}+">›</button></div></div>`;
    designer.innerHTML = `
      <div class="pmd-card">
        <div class="pmd-row"><span class="pmd-lbl">name</span>
          <input class="pmd-nameinput" id="pmd-nameinput" type="text" maxlength="24"
            placeholder="name your autopoet" autocomplete="off" spellcheck="false"></div>
        <div class="pmd-row"><span class="pmd-lbl">shape</span><div class="pmd-shapes">${
          shapes.map(s => `<button class="pmd-shp" data-s="${s.key}">${s.name}</button>`).join("")}</div></div>
        <div class="pmd-row"><span class="pmd-lbl">color</span><div class="pmd-swatches">${
          pal.map(p => `<button class="pmd-sw" data-c="${p.key}" title="${p.name}" style="background:radial-gradient(circle at 38% 32%, #fff 6%, ${p.body} 125%)"></button>`).join("")}</div></div>
      </div>
      <div class="pmd-card">
        ${pickRow("voice", "voice")}${pickRow("personality", "pers")}
        <button class="pmd-meet">meet your autopoet →</button>
      </div>`;
    document.body.appendChild(designer);

    const mark = () => {
      const c = (typeof getChar === "function") ? getChar() : {};
      designer.querySelectorAll(".pmd-sw").forEach(b => b.classList.toggle("on", b.dataset.c === c.color));
      designer.querySelectorAll(".pmd-shp").forEach(b => b.classList.toggle("on", b.dataset.s === c.shape));
    };
    designer.querySelectorAll(".pmd-sw").forEach(b => b.onclick = () => { setChar({ color: b.dataset.c }); applyCharacter(); mark(); });
    designer.querySelectorAll(".pmd-shp").forEach(b => b.onclick = () => { setChar({ shape: b.dataset.s }); applyCharacter(); mark(); });
    mark();

    const vn = designer.querySelector("#pmd-voice"), pn = designer.querySelector("#pmd-pers");
    const rv = () => vn.textContent = voices[vi].label;
    const rp = () => pn.textContent = personalities[pi].name;
    rv(); rp();
    if (board.setMotion) board.setMotion(personalities[pi].traits);   // idle motion matches the starting personality
    designer.querySelectorAll(".pmd-arw").forEach(b => b.onclick = () => {
      const k = b.dataset.k;
      if (k === "voice-") vi = (vi + voices.length - 1) % voices.length;
      if (k === "voice+") vi = (vi + 1) % voices.length;
      if (k === "pers-") pi = (pi + personalities.length - 1) % personalities.length;
      if (k === "pers+") pi = (pi + 1) % personalities.length;
      rv(); rp();
      // switching personality loads its motion profile (idle/bob/expressiveness)
      // and plays its signature — so you see how it MOVES, not just its name
      if (k.indexOf("pers") === 0) {
        if (board.setMotion) board.setMotion(personalities[pi].traits);
        if (board.signature) board.signature(personalities[pi].traits);
      }
    });
    // preview through board.previewVoice → the cube's mouth is AUDIO-DRIVEN
    // (visemes), same path the live call uses. Icon toggles play→loader→stop.
    let previewing = null;   // the button currently mid-preview
    const setIcon = (btn, n) => { btn.innerHTML = `<i data-lucide="${n}"></i>`; opts.refreshIcons && opts.refreshIcons(); };
    const resetPlays = () => designer.querySelectorAll(".pmd-play").forEach(b => b.innerHTML = `<i data-lucide="play"></i>`);
    const preview = (text, btn) => {
      // toggle off if this same button is already speaking
      if (previewing === btn) { board.hush(); previewing = null; setIcon(btn, "play"); return; }
      board.hush(); resetPlays(); opts.refreshIcons && opts.refreshIcons();
      previewing = btn; setIcon(btn, "loader");
      board.previewVoice(text, voices[vi].id, () => { if (previewing === btn) setIcon(btn, "square"); })
        .then(() => { if (previewing === btn) previewing = null; setIcon(btn, "play"); })
        .catch(() => { if (previewing === btn) previewing = null; setIcon(btn, "play"); });
    };
    designer.querySelector('[data-play="voice"]').onclick = e => preview("Hello — this is how I'll sound.", e.currentTarget.closest("button"));
    designer.querySelector('[data-play="pers"]').onclick = e => {
      if (board.signature) board.signature(personalities[pi].traits);   // move + speak in character
      preview((typeof AP_PSAMPLE !== "undefined" && AP_PSAMPLE[personalities[pi].key]) || "Let's build this together.", e.currentTarget.closest("button"));
    };
    designer.querySelector(".pmd-meet").onclick = async () => {
      board.hush();
      const c = (typeof getChar === "function") ? getChar() : {};
      const nameInput = designer.querySelector("#pmd-nameinput");
      const chosenName = (nameInput && nameInput.value || "").trim();   // names the AUTOPOET
      const user = (typeof currentUser !== "undefined" && currentUser) || {};
      const owner = user.name && user.name !== "demo" ? user.name : "";   // the human (greeting)
      let identity = null;
      try {
        const r = await fetch("/onboard/pick", { method: "POST",
          headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
          body: JSON.stringify({ ap_name: chosenName, voice: voices[vi].id, personality: personalities[pi].key, color: c.color, shape: c.shape, name: owner }) });
        if (r.ok) identity = await r.json();
      } catch (_) {}
      designer.remove(); designer = null;
      if (identity && identity.name) onFiled(identity);
    };
    opts.refreshIcons && opts.refreshIcons();
  }

  // form filed → BEAM the cube in (faceless, spinning, loading bar) while the
  // greeting synthesizes, then LAND with a personality-tuned wham and talk. The
  // beam hides first-synth latency; land waits on the real greeting clip.
  async function onFiled(identity) {
    formHost = null;
    pairing = identity || null;
    if (!pairing) return;           // the form retries until the office answers
    SCRIPT = scriptFromPairing(pairing);
    // the character's MOTION profile rides with it into the live conversation —
    // idle drift, speaking bob, and self-affect expressiveness all match it
    if (board && board.setMotion && pairing.traits) board.setMotion(pairing.traits);

    // the character's SHAPE is part of its identity — a blocky cube for a
    // serious voice, round for a warm one (color the owner keeps for later)
    if (identity && identity.shape && typeof setChar === "function") {
      try { setChar({ shape: identity.shape }); applyCharacter(); } catch (_) {}
    }

    board.deckReset();            // fresh deck — this session's pitch only
    board.beam();                 // drop in, spin, loading bar

    // land motion follows the voice's temperament: serious/blunt → a sudden
    // snap; lively/warm → a springy bounce
    const f = (identity && identity.form) || safeForm();
    const serious = f.energy === "calm" || f.manner === "blunt" ||
      (f.manner === "direct" && f.humor === "minimal");

    // streaming self-warms on say() (first audio ~0.8s), so the beam is just
    // the entrance animation now — hold it a beat, land, then the greeting
    // streams. warmFirst is a no-op under streaming (it would double-generate).
    const first = SCRIPT[0] ? SCRIPT[0].say : "";
    await board.warmFirst(first);
    await new Promise(res => setTimeout(res, 1300));   // let the beam play

    await board.land({ snap: serious });
    autoRun();
  }

  function safeForm() {
    try { return JSON.parse(sessionStorage.getItem("ap-form") || "{}"); } catch (_) { return {}; }
  }

  // auto-advance the opening (greeting + cover), then hand the session to the
  // brain. No step-navigation; the user can flip deck slides anytime.
  async function autoRun() {
    if (running) return;
    running = true;
    for (let n = 0; n < SCRIPT.length; n++) {
      if (!board) return;
      const s = SCRIPT[n];
      if (s.handoff) { onFirstQuestion(); break; }    // the conversation begins
      const tEnter = performance.now();

      if (s.slide) { await board.slide(s.slide); mountDeckNav(); }  // grows the pitch
      if (s.gesture === "wave") setTimeout(() => board.wave(), 250);
      if (SCRIPT[n + 1] && SCRIPT[n + 1].say) board.warm(SCRIPT[n + 1].say);

      // the LAST spoken beat before the handoff: PRIME the brain's first
      // question NOW so it fetches WHILE this greeting plays — no wait after
      if (SCRIPT[n + 1] && SCRIPT[n + 1].handoff && typeof PlanBrain !== "undefined" && PlanBrain.prime) {
        try { PlanBrain.prime(board, opts, pairing); } catch (_) {}
      }

      await board.say(s.say);     // resolves when the line finishes speaking
      const ms = Math.round(performance.now() - tEnter);
      (window.PM_TIMINGS = window.PM_TIMINGS || []).push({ step: n, ms });
      console.info("[pm] beat " + n + " performed in " + ms + "ms");
      await new Promise(r => setTimeout(r, 220));      // a breath between beats
    }
  }

  // the deck arrows — the ONE navigation the user gets: browse the pitch slides
  // (not the onboarding steps). Appears once the first slide is on the board.
  let deckNav = null;
  function mountDeckNav() {
    if (deckNav || !board) return;
    deckNav = document.createElement("div");
    deckNav.className = "pm-deck-nav";
    deckNav.innerHTML = `<button class="pm-arrow" id="pm-prev">‹</button>
      <button class="pm-arrow" id="pm-next">›</button>`;
    document.body.appendChild(deckNav);
    deckNav.querySelector("#pm-prev").onclick = () => board.deckPrev();
    deckNav.querySelector("#pm-next").onclick = () => board.deckNext();
  }

  // the scripted intro ends here → the CONVERSATION takes over: the brain asks
  // its own questions, forks three directions, and builds the deck live, until
  // it calls the plan complete and hands off to the build lane.
  function onFirstQuestion() {
    if (typeof PlanBrain !== "undefined" && PlanBrain.take) {
      try { PlanBrain.take(board, opts, pairing); return; } catch (_) {}
    }
    // brain unavailable → let them explore, then into the app
    if (tools) {
      const go = document.createElement("button");
      go.className = "pm-enter";
      go.textContent = "let's go →";
      go.onclick = () => { const d = opts.onDone; teardown(); d && d(); };
      tools.appendChild(go);
    }
  }

  // ── board camera: pan (drag) + zoom (wheel) on the D2 whiteboard, recenter ──
  const cam = { x: 0, y: 0, k: 1 };
  function bgEl() { return document.getElementById("vs-graph-bg"); }
  function camApply(animate) {
    const bg = bgEl(); if (!bg) return;
    bg.style.transition = animate ? "transform .5s cubic-bezier(.4,0,.2,1)" : "none";
    // KEEP the deck's own centering (its CSS is translate(-50%,-50%) off
    // left:50%/top:40%) — the pan/zoom composes ON TOP of it, else the deck
    // anchors its top-left at center and spills off-screen (the corner bug)
    bg.style.transform = `translate(-50%,-50%) translate(${cam.x}px,${cam.y}px) scale(${cam.k})`;
  }
  function camReset(animate) { cam.x = 0; cam.y = 0; cam.k = 1; camApply(animate); }
  function wireCamera() {
    const bg = bgEl(); if (!bg) return;
    bg.style.pointerEvents = "auto"; bg.style.cursor = "grab"; bg.style.transformOrigin = "50% 50%";
    let drag = null;
    bg.addEventListener("mousedown", e => { drag = { x: e.clientX - cam.x, y: e.clientY - cam.y }; bg.style.cursor = "grabbing"; e.preventDefault(); });
    window.addEventListener("mousemove", e => { if (!drag) return; cam.x = e.clientX - drag.x; cam.y = e.clientY - drag.y; camApply(false); });
    window.addEventListener("mouseup", () => { drag = null; bg.style.cursor = "grab"; });
    bg.addEventListener("wheel", e => {
      e.preventDefault();
      cam.k = Math.max(0.4, Math.min(2.5, cam.k * (e.deltaY < 0 ? 1.08 : 0.93)));
      camApply(false);
    }, { passive: false });
  }

  function teardown() {
    if (typeof exitCharacterMode === "function") { try { exitCharacterMode(); } catch (_) {} }
    document.body.classList.remove("pm-screen");
    running = false;
    if (typeof PlanBrain !== "undefined" && PlanBrain.teardown) { try { PlanBrain.teardown(); } catch (_) {} }
    if (formHost) { formHost.remove(); formHost = null; }
    if (designer) { designer.remove(); designer = null; }
    if (deckNav) { deckNav.remove(); deckNav = null; }
    if (tools) { tools.remove(); tools = null; }
    if (widget) { widget.remove(); widget = null; }
    if (board) { try { board.exit(); } catch (_) {} board = null; }
  }

  return { start, teardown };
})();
