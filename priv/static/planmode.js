// ── INTERACTIVE PLAN MODE — a thin driver over VoiceStage.stage({type:"plan"}) ──
// docs/interactive-plan-mode.md. NOTHING re-implemented: the ADOPTED self cube
// (the user's own set autopoet design — same body, same face, same soul as the
// voice call), bean hands, pointAt, the D2 whiteboard, progressive reveal,
// captions — all voice-stage.js, entered without audio. This file only owns the
// seed script + the bottom next/back widget. Phase 2 swaps the script for the
// brain loop (dynamic coverage).
window.PlanMode = (() => {

  // ONE cumulative D2 source — compiled once, revealed step by step (the exact
  // pattern the voice brain's [graph]/[+reveal] cues use). When the brain takes
  // over, it authors exactly this language.
  const D2_SRC = `
you: you
ap: your autopoet
mission: your mission
aud: audience
need: their need
build: what i weave {
  weave: a weave
  site: a live site
  sched: every morning
}
you -> ap: works with
ap -> mission: serves
mission -> aud: for
aud -> need: reveals
ap -> build.weave: builds
build.weave -> build.site: ships
build.sched -> build.weave: wakes
`;

  // step 0 = the CHARACTER opening: no graph, wave + hello.
  // the greeting knows YOU — the cloud identity synced your name at sign-in
  const seedName = () => {
    const n = (typeof currentUser !== "undefined" && currentUser && currentUser.name) || "";
    return n && n !== "demo" ? n.split(" ")[0].toLowerCase() : "";
  };
  const SEED = [
    { get say() { const n = seedName(); return `hi${n ? " " + n : ""} — i'm your autopoet. i turn your plain words into a living, running system. this board is where we design yours, together.`; },
      next: "say hi back →", gesture: "wave" },
    { say: "watch. everything starts with the two of us…",
      reveal: ["you", "you->ap"], point: "ap" },
    { say: "…and hangs off a mission. yours goes here — in your words, not mine.",
      reveal: ["ap->mission"], point: "mission" },
    { say: "then who it's for, and what they need…",
      reveal: ["mission->aud", "aud->need"], point: "aud" },
    { say: "…and the things i weave to meet it — tools, skills, apps, whatever fits your head. the shapes here are yours, not a form's.",
      reveal: ["ap->build.weave", "build.weave->build.site", "build.sched->build.weave"], point: "weave" },
    { say: "next i'll start asking YOU questions — one at a time — and this board fills with your real system.",
      end: true, gesture: "thumbsUp" }
  ];

  let opts, board, widget, step = -1, shown = false;

  function start(options) {
    opts = options || {};
    // plan mode is its OWN SCREEN: onboarding-first, no dashboard chrome —
    // the stage takes the viewport (body.pm-screen hides sidebar/console/bars)
    document.body.classList.add("pm-screen");
    board = VoiceStage.stage(Object.assign({ type: "plan" }, opts.stage || {}));
    if (!board) { document.body.classList.remove("pm-screen"); return false; }

    widget = document.createElement("div");
    widget.className = "pm-widget";
    widget.innerHTML = `
      <div class="pm-q" id="pm-q"></div>
      <div class="pm-nav">
        <span class="pm-tools">
          <button id="pm-sound" class="pm-ico" title="voice on/off"><i data-lucide="volume-2"></i></button>
          <button id="pm-recenter" class="pm-ico" title="recenter the board"><i data-lucide="crosshair"></i></button>
          <button id="pm-dev" class="pm-ico" title="behavior lab (dev)"><i data-lucide="sliders-horizontal"></i></button>
          <button id="pm-back" class="pm-btn ghost">← back</button>
        </span>
        <span class="pm-dots" id="pm-dots"></span>
        <button id="pm-next" class="pm-btn">next →</button>
      </div>`;
    document.body.appendChild(widget);
    widget.querySelector("#pm-back").onclick = () => go(step - 1);
    widget.querySelector("#pm-next").onclick = () => go(step + 1);

    // sound: Kokoro TTS of the lines (visemes run either way — perform()'s
    // silent path mouths the words to text cadence when sound is off)
    widget.querySelector("#pm-sound").onclick = () => {
      const on = board.setTTS(!board.ttsOn());
      widget.querySelector("#pm-sound").innerHTML = `<i data-lucide="${on ? "volume-2" : "volume-x"}"></i>`;
      opts.refreshIcons && opts.refreshIcons();
    };
    // recenter: snap the board's pan/zoom home
    widget.querySelector("#pm-recenter").onclick = () => camReset(true);
    // dev tools: the behavior lab rides THIS stage's verbs (voice switch + sliders)
    if (window.BehaviorLab) { BehaviorLab.attach(board); }
    widget.querySelector("#pm-dev").onclick = () => window.BehaviorLab && BehaviorLab.toggle();
    wireCamera();
    opts.refreshIcons && opts.refreshIcons();

    step = -1; shown = false;
    // pre-render: give Kokoro a beat to boot (≤2.5s), then warm every seed
    // line into the clip cache so each step SPEAKS instantly; if the engine
    // isn't up yet, perform() plays the same line as silent visemes
    const settle = (opts.stage && opts.stage.settleMs || 600) + 300;
    const t0 = performance.now();
    (function waitReady() {
      if (board.ready() || performance.now() - t0 > 2500) {
        SEED.forEach(st => board.warm(st.say));
        setTimeout(() => go(0), Math.max(0, settle - (performance.now() - t0)));
      } else setTimeout(waitReady, 150);
    })();
    return true;
  }

  async function go(n) {
    if (n < 0 || n >= SEED.length || !board) return;
    const backward = n < step;
    step = n;
    renderWidget();
    const s = SEED[n];

    // the board mounts on the first graph step — the opening is pure character
    if (s.reveal && !shown) { await board.show(D2_SRC); shown = true; }

    if (backward && shown) {
      // back = remount + re-walk (reveal() is additive-only)
      await board.show(D2_SRC);
      for (let i = 1; i <= n; i++) (SEED[i].reveal || []).forEach(r => board.reveal(r));
    } else {
      (s.reveal || []).forEach(r => board.reveal(r));
    }

    camReset(true);   // each step re-locks focus; wander + recenter anytime
    board.say(s.say);
    if (s.point) setTimeout(() => board.point(s.point, 3000), 500);
    if (s.gesture === "wave") setTimeout(() => board.wave(), 300);
    if (s.gesture === "thumbsUp") setTimeout(() => board.thumbsUp(), 400);
  }

  function renderWidget() {
    const s = SEED[step];
    // narration lives in the CAPTION (the performer's own voice line); the
    // question box only appears when the brain asks real questions (phase 2)
    const q = widget.querySelector("#pm-q");
    q.textContent = s.question || "";
    q.style.display = s.question ? "block" : "none";
    widget.querySelector("#pm-dots").innerHTML =
      SEED.map((_, i) => `<i class="${i === step ? "on" : ""}"></i>`).join("");
    widget.querySelector("#pm-back").style.visibility = step === 0 ? "hidden" : "visible";
    const next = widget.querySelector("#pm-next");
    if (s.end) {
      next.textContent = "enter the app →";
      next.onclick = () => { const done = opts.onDone; teardown(); done && done(); };
    } else {
      next.textContent = s.next || "next →";
      next.onclick = () => go(step + 1);
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
    document.body.classList.remove("pm-screen");
    if (widget) { widget.remove(); widget = null; }
    if (board) { try { board.exit(); } catch (_) {} board = null; }
  }

  return { start, teardown };
})();
