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
  const SEED = [
    { say: "hi — i'm your autopoet. i turn your plain words into a living, running system. this board is where we design yours, together.",
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
        <button id="pm-back" class="pm-btn ghost">← back</button>
        <span class="pm-dots" id="pm-dots"></span>
        <button id="pm-next" class="pm-btn">next →</button>
      </div>`;
    document.body.appendChild(widget);
    widget.querySelector("#pm-back").onclick = () => go(step - 1);
    widget.querySelector("#pm-next").onclick = () => go(step + 1);

    step = -1; shown = false;
    // let the cube's glide-to-center settle before the first line
    setTimeout(() => go(0), (opts.stage && opts.stage.settleMs || 600) + 300);
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

    board.say(s.say);
    if (s.point) setTimeout(() => board.point(s.point, 3000), 500);
    if (s.gesture === "wave") setTimeout(() => board.wave(), 300);
    if (s.gesture === "thumbsUp") setTimeout(() => board.thumbsUp(), 400);
  }

  function renderWidget() {
    const s = SEED[step];
    widget.querySelector("#pm-q").textContent = s.say;
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

  function teardown() {
    document.body.classList.remove("pm-screen");
    if (widget) { widget.remove(); widget = null; }
    if (board) { try { board.exit(); } catch (_) {} board = null; }
  }

  return { start, teardown };
})();
