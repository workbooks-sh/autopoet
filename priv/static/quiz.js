// AutopoetQuiz — the "set up your nexus" flow that ends onboarding.
//
// A STATE-MACHINE quiz, not a form: card questions (Lottie animations from the
// owned IconScout packs, micons for languages), each answer routes the next
// node, so a coder gets asked their language and their git laws while everyone
// else skips straight past. Answers post to /profile/set as they land
// (line-based file the brain reads to personalize the nexus on first wake).
//
// Card animations: static on their FIRST frame until hover, loop while hovered,
// FREEZE IN PLACE on mouse-out, and resume from that frame on re-hover — never
// restart from zero (lottie pause/play does exactly this).
//
// Deliberately its OWN file: app.html only supplies the container + hooks
// (authedPost / createFace / refreshIcons / onDone). gsap + lucide + lottie
// are globals.
(() => {
  const CSS = `
  #obquiz { display:none; flex-direction:column; align-items:center; gap:18px;
    width:600px; padding:40px; position:relative;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .qzskip { position:absolute; top:6px; right:10px; font:11px ui-monospace,monospace;
    color:#98a0ac; background:none; border:none; cursor:pointer; -webkit-app-region:no-drag; }
  .qzskip:hover { color:#3a4250; }
  .qzface { width:64px; height:64px; border-radius:15px; border:1px solid rgba(0,0,0,.12);
    background:#fff; overflow:hidden; flex:none; }
  .qzhead { text-align:center; max-width:460px; }
  .qzkicker { font:10.5px ui-monospace,monospace; color:#b3bac4; letter-spacing:.08em; }
  .qztitle { font:600 19px ui-monospace,monospace; color:#1c2230; margin-top:7px; }
  .qzsub { font:12px/1.6 ui-monospace,monospace; color:#67707c; margin:7px 0 0; }
  .qzcards { display:flex; flex-wrap:wrap; gap:12px; justify-content:center; width:100%; }
  .qzcard { position:relative; display:flex; flex-direction:column; align-items:center;
    gap:4px; width:158px; padding:14px 12px 13px; box-sizing:border-box;
    border:1px solid #d6dbe2; border-radius:16px; background:#fff; cursor:pointer;
    -webkit-app-region:no-drag; transition:border-color .16s ease, box-shadow .16s ease; }
  .qzcard:hover { border-color:#b9c2cd; box-shadow:0 1px 4px rgba(25,35,55,.1); }
  .qzcard.on { border-color:#6aa84f; box-shadow:0 0 0 3px rgba(106,168,79,.12); }
  .qzcard .qzlot { width:96px; height:96px; pointer-events:none; }
  .qzcard img.qzmic { width:44px; height:44px; margin:22px 0 26px; pointer-events:none; }
  .qzcard .qzglyph { width:30px; height:30px; margin:28px 0 30px; color:#3a4250; }
  .qzcard .qzglyph svg { width:30px; height:30px; }
  .qzname { font:600 12.5px ui-monospace,monospace; color:#1c2230; }
  .qzline { font:10.5px/1.45 ui-monospace,monospace; color:#67707c; text-align:center; min-height:29px; }
  .qzck { position:absolute; top:9px; right:9px; display:none; color:#6aa84f; }
  .qzck svg { width:15px; height:15px; }
  .qzcard.on .qzck { display:block; }
  .qznav { display:flex; align-items:center; gap:16px; min-height:34px; }
  .qzback { display:flex; align-items:center; justify-content:center; width:30px; height:30px;
    border:1px solid #d6dbe2; border-radius:9px; background:#fff; color:#67707c;
    cursor:pointer; -webkit-app-region:no-drag; }
  .qzback:hover { border-color:#b9c2cd; color:#1c2230; }
  .qzback svg { width:15px; height:15px; }
  .qzbar { width:120px; height:3px; border-radius:2px; background:#e4e8ee; overflow:hidden; }
  .qzbarfill { height:100%; width:0; border-radius:2px; background:#8e7cc3; }
  .qzgo { font:12.5px ui-monospace,monospace; padding:8px 17px; border-radius:10px;
    border:1px solid #2f6fdd; background:#2f6fdd; color:#fff; cursor:pointer;
    -webkit-app-region:no-drag; }
  .qzgo:hover { background:#245cc0; }
  .qzgo:disabled { border-color:#d6dbe2; background:#eef1f5; color:#b3bac4; cursor:default; }
  .qzchips { display:flex; flex-wrap:wrap; gap:8px; justify-content:center; max-width:440px; }
  .qzchip { font:11px ui-monospace,monospace; color:#3a4250; background:#fafbfc;
    border:1px solid #e4e8ee; border-radius:999px; padding:5px 11px; }
  .qzchip b { color:#8e7cc3; font-weight:600; }
  `;

  const lot = n => ({ lot: n });
  const mic = n => ({ mic: n });
  const gly = n => ({ gly: n });

  // ── the graph — every option carries its wry line; next() routes on state.
  // Synthesized from six persona passes (engineer, founder, fleet operator,
  // designer, student, ops owner): three skill-gated spines off "speak", a
  // universal policy trio (leash / pings / oops), and per-template branches.
  const afterGit = s => (s.speak === "fluent" ? "pen" : "narrate");
  const addon = s => {
    if (s.template === "agents") return "hours";
    if (s.template === "sites" || s.template === "apps") return s.speak === "fluent" ? "taste" : "start";
    if (s.template === "money") return "moneyrules";
    if (s.template === "blank" && s.speak !== "fluent") return "sandbox";
    return null;
  };
  const NODES = {
    template: {
      title: "what brings you here?",
      sub: "pick the closest. nothing is locked in — the nexus reshapes around you.",
      options: [
        { v: "blank", name: "blank slate", line: "an empty world. you shape it.", ...lot("plant-pot") },
        { v: "agents", name: "run agents", line: "a workforce that files its own work.", ...lot("delivery-boy") },
        { v: "apps", name: "build apps", line: "for yourself, or for everyone.", ...lot("hammer") },
        { v: "sites", name: "make websites", line: "things people can visit.", ...lot("online-store") },
        { v: "money", name: "make money", line: "ship something that sells.", ...lot("cashier-machine") },
      ],
      next: () => "speak",
    },
    speak: {
      title: "do you speak code?",
      sub: "no wrong answer. the machine adjusts its accent.",
      options: [
        { v: "fluent", name: "fluently", line: "i dream in stack traces.", ...lot("gaming-computer") },
        { v: "some", name: "a little", line: "i can read it, mostly.", ...lot("basic-learning") },
        { v: "none", name: "not a word", line: "that\'s the machine\'s job.", ...lot("creative-idea") },
      ],
      next: s => (s.speak === "fluent" ? "language" : s.speak === "some" ? "git" : "firstchore"),
    },

    // ── coder spine ──────────────────────────────────────────────────────────
    language: {
      title: "pick your poison",
      sub: "the nexus speaks every language. this one it speaks back to you.",
      options: [
        { v: "rust", name: "rust", line: "a cargo cultist. welcome.", ...mic("rust") },
        { v: "typescript", name: "typescript", line: "types are a love language.", ...mic("typescript") },
        { v: "python", name: "python", line: "whitespace believer.", ...mic("python") },
        { v: "elixir", name: "elixir", line: "let it crash.", ...mic("elixir") },
        { v: "go", name: "go", line: "boring on purpose.", ...mic("go") },
        { v: "javascript", name: "javascript", line: "chaos, but familiar.", ...mic("javascript") },
      ],
      next: () => "git",
    },
    git: {
      title: "how do you git?",
      sub: "if you have laws, the machine keeps them. on every change, forever.",
      options: [
        { v: "strict", name: "my way, exactly", line: "conventions are law.", ...lot("gps-navigator") },
        { v: "tidy", name: "keep it clean", line: "small commits, clear messages.", ...lot("broom") },
        { v: "vibes", name: "git happens", line: "history is a suggestion.", ...lot("gaming-error") },
      ],
      next: s => (s.git === "strict" ? "gitrules" : afterGit(s)),
    },
    gitrules: {
      title: "which laws?",
      sub: "pick any. these get enforced — not suggested — on every change.",
      multi: true,
      options: [
        { v: "conventional-commits", name: "conventional commits", line: "feat: fix: chore:", ...gly("git-commit") },
        { v: "branch-per-task", name: "one branch per task", line: "no drive-by changes.", ...gly("git-branch") },
        { v: "rebase-only", name: "rebase, never merge", line: "history is a straight line.", ...gly("git-merge") },
        { v: "tests-before-push", name: "tests before push", line: "red, green, then go.", ...gly("flask-conical") },
      ],
      next: afterGit,
    },
    pen: {
      title: "who holds the pen?",
      sub: "when the machine writes code, who gets to call it committed.",
      options: [
        { v: "branch-pr", name: "branch and propose", line: "it opens, you merge.", ...lot("pen-tool") },
        { v: "stage", name: "stage only", line: "leaves it in the tree.", ...lot("notepad") },
        { v: "commit", name: "it commits", line: "co-author trailer, honest history.", ...lot("ink-pen") },
        { v: "readonly", name: "never touch git", line: "the braid is yours.", ...lot("chest-guard") },
      ],
      next: () => "fence",
    },
    fence: {
      title: "where does the fence go?",
      sub: "pick what it never edits alone. everything else is fair game.",
      multi: true,
      options: [
        { v: "deps", name: "deps and lockfiles", line: "every dependency is a hire.", ...gly("package") },
        { v: "ci", name: "ci and release config", line: "the pipeline is law.", ...gly("settings") },
        { v: "secrets", name: "secrets and env", line: "obviously.", ...gly("lock") },
        { v: "nothing", name: "nothing is sacred", line: "brave. noted.", ...gly("flame") },
      ],
      next: () => "trust",
    },
    trust: {
      title: "new work appears. when do you trust it?",
      sub: "this decides what the machine shows you first.",
      options: [
        { v: "tests", name: "tests first", line: "red, green, believe.", ...lot("thermometer") },
        { v: "examples", name: "show me examples", line: "seeing is believing.", ...lot("binoculars") },
        { v: "run-it", name: "i\'ll just run it", line: "faith-based engineering.", ...lot("paragliding") },
      ],
      next: () => "research",
    },
    research: {
      title: "before building something new?",
      sub: "how much of the map do you want first?",
      options: [
        { v: "deep", name: "read everything", line: "then begin.", ...lot("bookshelf") },
        { v: "skim", name: "a quick look", line: "enough to not reinvent it.", ...lot("map") },
        { v: "greenfield", name: "just build", line: "the field is greener untouched.", ...lot("forest") },
      ],
      next: () => "pings",
    },

    // ── learner spine (speak = a little) ─────────────────────────────────────
    narrate: {
      title: "should the machine narrate?",
      sub: "it can explain every move while it works, or keep quiet.",
      options: [
        { v: "teach", name: "narrate everything", line: "every move, plain words.", ...lot("mic") },
        { v: "highlights", name: "just the good parts", line: "only the interesting bits.", ...lot("spotlight") },
        { v: "quiet", name: "just do it", line: "you\'ll ask when curious.", ...lot("headphones") },
      ],
      next: s => (s.narrate === "quiet" ? "firstwin" : "depth"),
    },
    depth: {
      title: "how deep should explanations go?",
      sub: "when it explains, pick the altitude.",
      options: [
        { v: "eli5", name: "like i\'m five", line: "analogies, no scary words.", ...lot("happy-kid") },
        { v: "code", name: "point at the code", line: "show the actual lines.", ...lot("e-learning") },
        { v: "both", name: "analogy, then code", line: "warm up, then the real thing.", ...lot("knowledge") },
      ],
      next: () => "firstwin",
    },
    firstwin: {
      title: "what counts as a first win?",
      sub: "the first session ends when this happens.",
      options: [
        { v: "visible", name: "something on screen", line: "a node lights up. you grin.", ...lot("arcade-game") },
        { v: "automated", name: "a chore automated", line: "the machine does the boring thing.", ...lot("dishwasher") },
        { v: "understood", name: "something understood", line: "you walk away smarter.", ...lot("graduation-cap") },
      ],
      next: () => "leash",
    },

    // ── civilian spine (speak = not a word) — zero jargon past this line ─────
    firstchore: {
      title: "what should it take off your plate first?",
      sub: "pick the chore you\'d happily never do again.",
      options: [
        { v: "inbox", name: "tame my inbox", line: "sort, draft, flag the scary ones.", ...lot("weather-alert") },
        { v: "money", name: "chase the money", line: "invoices, reminders, who owes what.", ...lot("online-funds") },
        { v: "words", name: "write the words", line: "newsletters, posts, blurbs.", ...lot("writing") },
        { v: "shop", name: "mind the shop", line: "orders, listings, boring updates.", ...lot("online-shop") },
      ],
      next: () => "watch",
    },
    watch: {
      title: "what may it read?",
      sub: "it works better with eyes. they\'re your eyes.",
      options: [
        { v: "mail", name: "my email", line: "read yes, send no.", ...lot("parachute-delivery") },
        { v: "files", name: "my files", line: "docs, sheets, the drive.", ...lot("medical-record") },
        { v: "both", name: "the lot", line: "email and files, read-only.", ...lot("grocery-basket") },
        { v: "none", name: "nothing yet", line: "earn it first.", ...lot("scuba-mask") },
      ],
      next: s => (s.watch === "none" ? "voice" : "offlimits"),
    },
    offlimits: {
      title: "what should it pretend not to see?",
      sub: "not shared, not even read.",
      options: [
        { v: "payroll", name: "payroll and hr", line: "paychecks are sacred.", ...lot("billing-system") },
        { v: "personal", name: "personal threads", line: "family, doctors, the accountant.", ...lot("photo-frame") },
        { v: "clients", name: "client financials", line: "their numbers stay theirs.", ...lot("donation-box") },
        { v: "nothing", name: "nothing off-limits", line: "it all stays on this machine anyway.", ...lot("sunglasses") },
      ],
      next: () => "voice",
    },
    voice: {
      title: "how should it talk to you?",
      sub: "pick a voice you won\'t dread reading.",
      options: [
        { v: "plain", name: "plain english", line: "like a sharp assistant.", ...lot("crayon-box") },
        { v: "short", name: "bullet points", line: "headlines only, no essays.", ...lot("stationery-holder") },
        { v: "warm", name: "friendly", line: "a little charm is fine.", ...lot("teacup") },
      ],
      next: () => "leash",
    },

    // ── the policy trio — everyone answers these, each in their own words ────
    leash: {
      title: "how long is the leash?",
      sub: "how much it may do before checking with you.",
      options: [
        { v: "ask", name: "always ask", line: "nothing happens without a nod.", ...lot("butler-bell") },
        { v: "fenced", name: "free inside the fence", line: "act within limits, ask past them.", ...lot("pet-house") },
        { v: "loose", name: "off the leash", line: "act now, confess in the log.", ...lot("hot-balloon") },
      ],
      next: () => "pings",
    },
    pings: {
      title: "when may it interrupt you?",
      sub: "your attention is the scarcest budget.",
      options: [
        { v: "live", name: "ping me live", line: "every event, as it happens.", ...lot("radio-music") },
        { v: "digest", name: "one daily note", line: "everything, once, with coffee.", ...lot("moka-pot") },
        { v: "fires", name: "emergencies only", line: "silence means all clear.", ...lot("first-aid") },
      ],
      next: () => "oops",
    },
    oops: {
      title: "when something breaks?",
      sub: "and something will. everything here can be undone.",
      options: [
        { v: "freeze", name: "stop and confess", line: "freeze and come get you.", ...lot("winter-jacket") },
        { v: "revert", name: "put it back", line: "undo to last good, then ask.", ...lot("mop-bucket") },
        { v: "quiet", name: "fix it quietly", line: "retry, tell you after.", ...lot("spray-bottle") },
      ],
      next: addon,
    },

    // ── per-world branches ───────────────────────────────────────────────────
    hours: {
      title: "when does the fleet run?",
      sub: "machines don\'t sleep. you do.",
      options: [
        { v: "always", name: "always on", line: "work never stops.", ...lot("gaming-setup") },
        { v: "nights", name: "while you sleep", line: "wake up to finished work.", ...lot("bedroll") },
        { v: "summoned", name: "only when summoned", line: "idle until you say go.", ...lot("joystick") },
      ],
      next: () => "burn",
    },
    burn: {
      title: "pick a burn ceiling",
      sub: "a hard cap, set before anything runs.",
      options: [
        { v: "pocket", name: "pocket change", line: "a few dollars a day.", ...lot("banana") },
        { v: "line-item", name: "a real line item", line: "predictable monthly spend.", ...lot("appointment-schedule") },
        { v: "fuel", name: "spend to win", line: "outcomes first, invoice later.", ...lot("campsite-fire") },
      ],
      next: () => null,
    },
    start: {
      title: "where do ideas live first?",
      sub: "before it\'s real, it\'s somewhere.",
      options: [
        { v: "sketch", name: "napkin first", line: "you draw it, it builds it.", ...lot("digital-drawing") },
        { v: "reference", name: "i bring receipts", line: "links, screenshots, stolen beauty.", ...lot("camera") },
        { v: "words", name: "i can describe it", line: "adjectives until something clicks.", ...lot("thread-spool") },
        { v: "options", name: "show me things", line: "you know it when you see it.", ...lot("color-palette") },
      ],
      next: () => "taste",
    },
    taste: {
      title: "how loud should it look?",
      sub: "your default, not your only setting.",
      options: [
        { v: "whisper", name: "quiet and minimal", line: "whitespace does the work.", ...lot("singing-bowl") },
        { v: "measured", name: "restrained but warm", line: "calm, with a pulse.", ...lot("flower-plant") },
        { v: "loud", name: "expressive", line: "big type, zero apologies.", ...lot("saxophone") },
        { v: "depends", name: "per project", line: "read the room every time.", ...lot("dropper-tool") },
      ],
      next: () => "motion",
    },
    motion: {
      title: "should things move?",
      sub: "the animation budget, roughly.",
      options: [
        { v: "still", name: "barely", line: "a fade, on a good day.", ...lot("beach-chair") },
        { v: "purposeful", name: "only with purpose", line: "motion explains, never decorates.", ...lot("pottery-wheel") },
        { v: "alive", name: "everything breathes", line: "springs, easing, small delights.", ...lot("beach-ball") },
      ],
      next: () => null,
    },
    moneyrules: {
      title: "and when money\'s involved?",
      sub: "because money mistakes sting the most.",
      options: [
        { v: "never", name: "never touch money", line: "not even to look.", ...lot("boxing-gloves") },
        { v: "read", name: "read and add up", line: "totals, due dates, that\'s it.", ...lot("glucose-meter") },
        { v: "flag", name: "flag what\'s off", line: "over budget, double-billed, weird.", ...lot("forecast-reporting") },
        { v: "chase", name: "draft the chasers", line: "late-payer nudges, you send them.", ...lot("car-tracker") },
      ],
      next: () => null,
    },
    sandbox: {
      title: "playground or real thing?",
      sub: "where day one starts.",
      options: [
        { v: "playground", name: "playground first", line: "break stuff. nothing matters.", ...lot("kid-playing") },
        { v: "real", name: "my idea, training wheels", line: "real project, machine spots you.", ...lot("trekking-pole") },
        { v: "demo", name: "surprise me", line: "a world that already works.", ...lot("gaming-device") },
      ],
      next: () => null,
    },
  };
  const START = "template";

  // labels for the recap chips — keys read as plain words
  const KEY_LABEL = {
    template: "world", speak: "code", language: "language",
    git: "git", gitrules: "laws", pen: "pen", fence: "fence",
    trust: "trust", research: "research",
    narrate: "narration", depth: "depth", firstwin: "first win",
    firstchore: "first job", watch: "reads", offlimits: "off-limits", voice: "voice",
    leash: "leash", pings: "pings", oops: "breakage",
    hours: "hours", burn: "budget",
    start: "starts with", taste: "taste", motion: "motion",
    moneyrules: "money", sandbox: "day one",
  };

  let state = {}, history = [], hooks = {}, root = null, faceApi = null;

  const save = (k, v) =>
    hooks.post && hooks.post(`/profile/set?key=${encodeURIComponent(k)}&value=${encodeURIComponent(v)}`);

  // remaining-path estimate for the progress bar (walks next() on current state)
  function remaining(id) {
    let n = 0;
    while (id) { n++; id = NODES[id].next(state); if (n > 24) break; }
    return n;
  }

  function media(o) {
    if (o.lot) return `<div class="qzlot" data-lot="${o.lot}"></div>`;
    if (o.mic) return `<img class="qzmic" src="/static/micons/${o.mic}.svg" alt="">`;
    return `<span class="qzglyph"><i data-lucide="${o.gly}"></i></span>`;
  }

  // ── card animations: first-frame static → loop on hover → freeze on leave →
  //    RESUME from the frozen frame on re-hover (pause/play, never a restart) ──
  let anims = [];
  function destroyAnims() { anims.forEach(a => a.destroy()); anims = []; }
  function initLotties(scope) {
    scope.querySelectorAll(".qzlot").forEach(el => {
      const anim = lottie.loadAnimation({
        container: el, renderer: "svg", loop: true, autoplay: !!el.dataset.auto,
        path: `/static/lotties/${el.dataset.lot}.json`,
      });
      anim.addEventListener("DOMLoaded", () => { if (!el.dataset.auto) anim.goToAndStop(0, true); });
      anims.push(anim);
      const card = el.closest(".qzcard");
      if (!card) return;
      card.addEventListener("mouseenter", () => anim.play());
      card.addEventListener("mouseleave", () => anim.pause());
    });
  }

  function render(id, dir) {
    const node = NODES[id];
    const body = root.querySelector(".qzbody");
    const build = () => {
      destroyAnims();
      const picked = (state[id] || "").split(",").filter(Boolean);
      body.innerHTML = `
        <div class="qzhead">
          <div class="qzkicker">setting up your nexus</div>
          <div class="qztitle">${node.title}</div>
          <p class="qzsub">${node.sub}</p>
        </div>
        <div class="qzcards">${node.options.map((o, i) => `
          <button class="qzcard${picked.includes(o.v) ? " on" : ""}" data-i="${i}">
            <span class="qzck"><i data-lucide="check"></i></span>
            ${media(o)}
            <span class="qzname">${o.name}</span>
            <span class="qzline">${o.line}</span>
          </button>`).join("")}
        </div>
        <div class="qznav">
          ${history.length ? `<button class="qzback" title="back"><i data-lucide="arrow-left"></i></button>` : ""}
          <div class="qzbar"><div class="qzbarfill"></div></div>
          ${node.multi ? `<button class="qzgo" ${picked.length ? "" : "disabled"}>continue</button>` : ""}
        </div>`;
      (hooks.refreshIcons || (() => {}))();
      initLotties(body);

      const done = history.length + 1;
      gsap.to(body.querySelector(".qzbarfill"),
        { width: `${Math.round(100 * done / (done + remaining(node.next(state)) ))}%`, duration: .5, ease: "power2.out" });

      body.querySelectorAll(".qzcard").forEach(card => card.onclick = () => {
        const o = node.options[+card.dataset.i];
        if (node.multi) {
          card.classList.toggle("on");
          const on = [...body.querySelectorAll(".qzcard.on")].map(c => node.options[+c.dataset.i].v);
          state[id] = on.join(",");
          body.querySelector(".qzgo").disabled = !on.length;
          gsap.fromTo(card, { scale: .96 }, { scale: 1, duration: .3, ease: "back.out(3)" });
          return;
        }
        body.querySelectorAll(".qzcard").forEach(c => c.classList.remove("on"));
        card.classList.add("on");
        state[id] = o.v;
        save(id, o.v);
        gsap.fromTo(card, { scale: .96 }, { scale: 1, duration: .3, ease: "back.out(3)" });
        setTimeout(() => advance(id), 300);
      });
      const back = body.querySelector(".qzback");
      if (back) back.onclick = () => { const prev = history.pop(); render(prev, -1); };
      const go = body.querySelector(".qzgo");
      if (go) go.onclick = () => { save(id, state[id] || ""); advance(id); };

      gsap.fromTo(body, { x: 26 * dir, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: .4, ease: "power2.out" });
      gsap.from(body.querySelectorAll(".qzcard"),
        { y: 10, autoAlpha: 0, duration: .35, delay: .08, stagger: .05, ease: "power2.out" });
    };
    gsap.to(body, { x: -26 * dir, autoAlpha: 0, duration: .2, ease: "power1.in", onComplete: build });
    if (faceApi) faceApi.setMouth(node.mood || "neutral");
  }

  function advance(id) {
    const nxt = NODES[id].next(state);
    history.push(id);
    if (nxt) return render(nxt, 1);
    finale();
  }

  function finale() {
    if (faceApi) faceApi.setMouth("superHappy");
    const body = root.querySelector(".qzbody");
    const chips = Object.entries(state)
      .filter(([, v]) => v)
      .map(([k, v]) => `<span class="qzchip"><b>${KEY_LABEL[k] || k}</b> ${v.replaceAll(",", " · ")}</span>`)
      .join("");
    const build = () => {
      destroyAnims();
      body.innerHTML = `
        <div class="qzhead">
          <div class="qzkicker">setting up your nexus</div>
          <div class="qztitle">your nexus is taking shape</div>
          <p class="qzsub">the autopoet reads these when it wakes. change your mind anytime — it's all just text.</p>
        </div>
        <div class="qzlot" data-lot="tournament-victory" data-auto="1" style="width:110px;height:110px"></div>
        <div class="qzchips">${chips}</div>
        <div class="qznav"><button class="qzgo" id="qzenter">enter autopoet</button></div>`;
      body.querySelector("#qzenter").onclick = () => hooks.onDone && hooks.onDone();
      initLotties(body);
      gsap.fromTo(body, { x: 26, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: .4, ease: "power2.out" });
      gsap.from(body.querySelectorAll(".qzchip"),
        { y: 8, autoAlpha: 0, duration: .3, delay: .12, stagger: .05, ease: "power2.out" });
    };
    gsap.to(body, { x: -26, autoAlpha: 0, duration: .2, ease: "power1.in", onComplete: build });
  }

  function start(container, h) {
    hooks = h || {};
    state = {}; history = [];
    root = container;
    destroyAnims();
    if (!document.getElementById("qzcss")) {
      const st = document.createElement("style");
      st.id = "qzcss"; st.textContent = CSS;
      document.head.appendChild(st);
    }
    container.innerHTML = `
      <button class="qzskip">skip →</button>
      <div class="qzface"></div>
      <div class="qzbody" style="display:flex;flex-direction:column;align-items:center;gap:18px;width:100%"></div>`;
    container.querySelector(".qzskip").onclick = () => {
      if (!state.template) save("template", "blank");
      hooks.onDone && hooks.onDone();
    };
    if (hooks.createFace)
      hooks.createFace(container.querySelector(".qzface"), { idPrefix: "qz" }).then(api => { faceApi = api; });
    render(START, 1);
  }

  window.AutopoetQuiz = { start, _anims: () => anims };
})();
