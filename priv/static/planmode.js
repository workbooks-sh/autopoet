// ── INTERACTIVE PLAN MODE — a thin driver over VoiceStage.stage({type:"plan"}) ──
// docs/interactive-plan-mode.md. NOTHING re-implemented: the ADOPTED self cube
// (the user's own set autopoet design — same body, same face, same soul as the
// voice call), bean hands, pointAt, the D2 whiteboard, progressive reveal,
// captions — all voice-stage.js, entered without audio. This file only owns the
// seed script + the bottom next/back widget. Phase 2 swaps the script for the
// brain loop (dynamic coverage).
window.PlanMode = (() => {

  // fallback intro when there's NO pairing at all (form + LLM both unavailable
  // — rare; the requisition ships a deterministic pitch even offline). Pure
  // character, one built-in pitch slide, then the first question.
  const seedName = () => {
    const n = (typeof currentUser !== "undefined" && currentUser && currentUser.name) || "";
    return n && n !== "demo" ? n.split(" ")[0].toLowerCase() : "";
  };
  const SEED = [
    { get say() { const n = seedName(); return `hi${n ? " " + n : ""} — i'm your autopoet. i turn your plain words into a living, running system.`; },
      gesture: "wave" },
    { say: "here's the shape of it — you speak, i weave, and something real ships.",
      slide: "# the plan\n\n- you bring the words\n- i weave the system\n- it ships, and wakes up every morning" },
    { say: "so — tell me what you're actually here to build.",
      question: true, gesture: "lean" }
  ];

  let opts, board, widget, tools, formHost = null, running = false;
  let SCRIPT = SEED;

  // the requisition pairing → the performed PITCH. The character comes out of
  // the gate, introduces itself, then builds a reveal.js DECK slide by slide
  // from the requester's own marks (emergent — every slide is theirs), then
  // asks the first question. Auto-advances; the user can flip slides freely.
  function scriptFromPairing(p) {
    const slides = (p.slides || [])
      .filter(st => st.say && st.md)
      .map(st => ({ say: st.say, slide: st.md }));
    return [
      { say: p.greeting || SEED[0].say, gesture: "wave" },
      ...slides,
      { say: "that's the sketch — and it grows as we go. so, first thing: tell me what you're actually here to build.",
        question: true, gesture: "lean" }
    ];
  }

  // ── mount: standalone stage (own grid + own cube, SEPARATE from the
  //    dashboard graph), form on the grid, character enters, auto-performs ──
  function start(options) {
    opts = options || {};
    document.body.classList.add("pm-screen");
    // onboarding is its OWN stage — no adopt, no app world hooks. The stage
    // owns a white grid + its own cube, held offstage until the form is filed.
    const stageOpts = Object.assign({ type: "plan", hold: true }, opts.stage || {});
    delete stageOpts.adopt; delete stageOpts.selfSpot;
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

    // PREVIEW MODE (lab "restart in this voice"): a pairing is handed in — skip
    // the form, bring the character straight in on the current default voice.
    if (opts.pairing) { onFiled(opts.pairing); return true; }

    // THE FORM — mounted on the stage grid (white card), not the beige overlay
    formHost = window.Requisition.buildForm(onFiled);
    (document.getElementById("stage") || document.body).appendChild(formHost);
    requestAnimationFrame(() => formHost.classList.add("rq-in"));
    return true;
  }

  // form filed → set the script, warm the voice, bring the character in, run
  async function onFiled(identity) {
    formHost = null;
    if (identity && Array.isArray(identity.slides) && identity.slides.length) {
      SCRIPT = scriptFromPairing(identity);
    } else { SCRIPT = SEED; }

    // give the engine a beat to warm (it was booted at submit), then warm the
    // clip cache so the entrance line speaks instantly
    const t0 = performance.now();
    await new Promise(res => {
      (function w() {
        if (board.ready() || performance.now() - t0 > 2500) res();
        else setTimeout(w, 150);
      })();
    });
    SCRIPT.forEach(st => board.warm(st.say));

    await board.deckReset();      // fresh deck — this session's pitch only
    await board.enter();          // the cube pops in at center + waves
    autoRun();
  }

  // auto-advance: perform each beat, wait for narration to finish, proceed.
  // Zero step-navigation — the intro drives itself. Each pitch beat appends a
  // slide to the deck; the user can flip slides with the ‹ › arrows anytime.
  async function autoRun() {
    if (running) return;
    running = true;
    for (let n = 0; n < SCRIPT.length; n++) {
      if (!board) return;
      const s = SCRIPT[n];
      const tEnter = performance.now();

      if (s.slide) { await board.slide(s.slide); mountDeckNav(); }  // grows the pitch
      if (s.gesture === "wave") setTimeout(() => board.wave(), 250);
      if (s.gesture === "lean") setTimeout(() => board.nod && board.nod(0.5), 250);
      if (SCRIPT[n + 1]) board.warm(SCRIPT[n + 1].say);

      await board.say(s.say);     // resolves when the line finishes speaking
      const ms = Math.round(performance.now() - tEnter);
      (window.PM_TIMINGS = window.PM_TIMINGS || []).push({ step: n, ms });
      console.info("[pm] beat " + n + " performed in " + ms + "ms");

      if (s.question) { onFirstQuestion(); break; }   // hand off (phase 2 brain)
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

  // the first real question is where the scripted intro ends. Phase 2 wires the
  // brain loop here; for now the diagram is built and the board is theirs.
  function onFirstQuestion() {
    if (typeof PlanBrain !== "undefined" && PlanBrain.take) {
      try { PlanBrain.take(board, opts); return; } catch (_) {}
    }
    // no brain yet → let them explore, then into the app
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
    bg.style.transform = `translate(${cam.x}px,${cam.y}px) scale(${cam.k})`;
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
    if (formHost) { formHost.remove(); formHost = null; }
    if (deckNav) { deckNav.remove(); deckNav = null; }
    if (tools) { tools.remove(); tools = null; }
    if (widget) { widget.remove(); widget = null; }
    if (board) { try { board.exit(); } catch (_) {} board = null; }
  }

  return { start, teardown };
})();
