// ── THE PLAN CONVERSATION — the autopoet talks while authoring the deck ─────
// Takes over from the scripted intro (planmode's onFirstQuestion). Emergent:
// the brain (/plan/turn) decides every question and slide. The one fixed beat
// is the three-direction fork the owner clicks. The owner can answer, ask, or
// interject anytime through the bar at the bottom. When the brain calls the
// deck complete, we hand off to the build lane (vault + graph fill).
window.PlanBrain = (() => {
  let board, opts, state, running = false;
  let bar, askResolve = null, deckNav = null;

  async function take(b, o, pairing) {
    board = b; opts = o || {};
    const titles = ((pairing && pairing.slides) || []).map(s => (s.md.match(/^#+\s*(.+)$/m) || [])[1] || "");
    state = {
      form: (pairing && pairing.form) || safeForm(),
      pairing: pairing || {},
      history: [],
      fork_done: false,
      deck_titles: titles
    };
    mountBar();
    running = true;
    loop();
  }

  function safeForm() {
    try { return JSON.parse(sessionStorage.getItem("ap-form") || "{}"); } catch (_) { return {}; }
  }

  // the interjection bar: answer, ask, or speak past — always available
  function mountBar() {
    if (bar) return;
    bar = document.createElement("div");
    bar.className = "pm-bar";
    bar.innerHTML = `
      <div id="pm-qpin"></div>
      <div class="pm-bar-row">
        <input id="pm-say" placeholder="answer, ask, or say anything…" autocomplete="off" spellcheck="false">
        <button id="pm-send" class="pm-send" title="send">→</button>
      </div>`;
    document.body.appendChild(bar);
    const input = bar.querySelector("#pm-say");
    const fire = () => {
      const t = input.value.trim();
      if (!t) return;
      input.value = "";
      send(t);
    };
    bar.querySelector("#pm-send").onclick = fire;
    input.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); fire(); } });
    setTimeout(() => input.focus(), 200);
  }

  // owner speaks → into history; if the brain was waiting on an answer, release
  function send(text) {
    bubble("you", text);
    state.history.push({ role: "user", content: text });
    if (askResolve) { const r = askResolve; askResolve = null; r(); }
  }

  function waitForUser() { return new Promise(res => { askResolve = res; }); }

  function pinQuestion(text) {
    const pin = bar && bar.querySelector("#pm-qpin");
    if (!pin) return;
    pin.textContent = text || "";
    pin.classList.toggle("on", !!text);
  }

  async function loop() {
    let misses = 0, prefetch = null;
    while (running && board) {
      // PIPELINE: a prefetched turn (started during the previous narration)
      // lands with zero dead air; otherwise pay the call now
      const move = prefetch ? await prefetch : await postTurn();
      prefetch = null;
      if (!running) break;
      if (!move) {
        // a hiccup, not a script: note it and retry — the brain is the only
        // source of words, so we wait for it rather than faking a line
        misses++;
        if (misses <= 3) { await new Promise(r => setTimeout(r, 2200)); continue; }
        bubble("ap", "…connection's rough. say anything to nudge me.");
        await waitForUser();
        misses = 0;
        continue;
      }
      misses = 0;

      // voice first: the say's clips start synthesizing IMMEDIATELY (the deck
      // compile and everything else overlaps the synth, not the other way)
      if (move.say && board.warm) board.warm(move.say);
      // a slide/complete move grows the deck first, then narrates over it
      if (move.md) {
        await board.slide(move.md);
        state.deck_titles.push(move.title || "");
        mountDeckNav();
      }
      state.history.push({ role: "assistant", content: move.say });
      // bare slide moves auto-continue → fetch the NEXT turn while this one
      // narrates; the LLM latency hides entirely behind the speech
      if (move.move === "slide") prefetch = postTurn();
      // the FULL question stays readable above the input while it's open —
      // the spoken caption is transient, this pin is not
      if (move.move === "ask") pinQuestion(move.say);
      await board.say(move.say);       // resolves when narration ends

      if (move.move === "ask") {
        await waitForUser();           // block until the owner responds
        pinQuestion(null);
      } else if (move.move === "fork") {
        const pick = await showFork(move.options || []);
        state.history.push({ role: "user", content: "let's go with: " + pick.title });
        state.fork_done = true;
        if (board && board.think) board.think(true);   // thought while the next turn runs
        if (pick.md) { await board.slide(pick.md); state.deck_titles.push(pick.title); mountDeckNav(); }
      } else if (move.move === "complete") {
        await finish(move);
        break;
      }
      // "slide" → continue; if the owner interjected mid-flow, the next
      // postTurn carries their message and the brain responds to it
    }
  }

  async function postTurn() {
    try {
      const r = await fetch("/plan/turn", {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify({
          form: state.form, pairing: state.pairing, history: state.history.slice(-20),
          fork_done: state.fork_done, deck_titles: state.deck_titles.slice(-12)
        })
      });
      if (!r.ok) return null;
      return await r.json();
    } catch (_) { return null; }
  }

  // ── the three-direction fork — the one thing the owner physically picks ──
  function showFork(options) {
    return new Promise(resolve => {
      const wrap = document.createElement("div");
      wrap.className = "pm-fork";
      wrap.innerHTML = `<div class="pm-fork-cards">` +
        options.map((o, i) => `
          <button class="pm-card" data-i="${i}">
            <div class="pm-card-k">direction ${String.fromCharCode(65 + i)}</div>
            <div class="pm-card-t">${escapeHtml(o.title)}</div>
            <div class="pm-card-m">${escapeHtml(oneLine(o.md))}</div>
          </button>`).join("") + `</div>`;
      document.body.appendChild(wrap);
      requestAnimationFrame(() => wrap.classList.add("on"));
      wrap.querySelectorAll(".pm-card").forEach(btn => {
        btn.onclick = () => {
          const pick = options[+btn.dataset.i];
          wrap.querySelectorAll(".pm-card").forEach(b => b.classList.toggle("picked", b === btn));
          wrap.classList.add("done");
          bubble("you", "→ " + pick.title);
          setTimeout(() => { wrap.remove(); resolve(pick); }, 520);
        };
      });
    });
  }

  // ── completion → processing → the build lane (vault + graph fill) ──
  async function finish(move) {
    if (bar) { bar.remove(); bar = null; }
    const proc = document.createElement("div");
    proc.className = "pm-proc";
    proc.innerHTML = `
      <div class="pm-proc-cube"></div>
      <div class="pm-proc-txt">weaving your vault<span class="pm-dots3"><i>.</i><i>.</i><i>.</i></span></div>
      <div class="pm-proc-sub">turning the plan into working files</div>`;
    document.body.appendChild(proc);
    requestAnimationFrame(() => proc.classList.add("on"));

    // kick the build lane: the deck (already persisted slide-by-slide via the
    // stage's /voice/deck/add) becomes the seed the intake agent compiles into
    // the first vault + graph. Onboarding is marked done; the app takes over
    // showing the graph fill.
    try {
      await fetch("/intake/start", { method: "POST", headers: { authorization: "Bearer " + TOKEN } });
    } catch (_) {}
    setTimeout(() => { const d = opts.onDone; d && d(); }, 2600);
  }

  // ── deck arrows (browse the pitch) + chat bubbles ──
  function mountDeckNav() {
    if (deckNav || !board) return;
    const existing = document.querySelector(".pm-deck-nav");   // planmode may have mounted one
    if (existing) { deckNav = existing; return; }
    deckNav = document.createElement("div");
    deckNav.className = "pm-deck-nav";
    deckNav.innerHTML = `<button class="pm-arrow" id="pmb-prev">‹</button><button class="pm-arrow" id="pmb-next">›</button>`;
    document.body.appendChild(deckNav);
    deckNav.querySelector("#pmb-prev").onclick = () => board.deckPrev();
    deckNav.querySelector("#pmb-next").onclick = () => board.deckNext();
  }

  function bubble(who, text) {
    let log = document.getElementById("pm-chat");
    if (!log) {
      log = document.createElement("div"); log.id = "pm-chat"; log.className = "pm-chat";
      document.body.appendChild(log);
    }
    const b = document.createElement("div");
    b.className = "pm-bub " + (who === "you" ? "you" : "ap");
    b.textContent = text;
    log.appendChild(b);
    while (log.children.length > 4) log.removeChild(log.firstChild);
    setTimeout(() => { b.classList.add("fade"); }, 4200);
  }

  function teardown() {
    running = false;
    [bar, deckNav, document.getElementById("pm-chat")].forEach(el => el && el.remove());
    bar = null; deckNav = null;
    document.querySelectorAll(".pm-fork,.pm-proc").forEach(el => el.remove());
  }

  const escapeHtml = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const oneLine = md => String(md).replace(/^#+\s*/gm, "").replace(/[`*_>-]/g, "").split("\n").map(x => x.trim()).filter(Boolean).slice(0, 1)[0] || "";

  return { take, teardown };
})();
