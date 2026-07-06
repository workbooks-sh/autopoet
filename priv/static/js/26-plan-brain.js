// ── THE PLAN CONVERSATION — the autopoet talks while authoring the deck ─────
// Takes over from the scripted intro (planmode's onFirstQuestion). Emergent:
// the brain (/plan/turn) decides every question and slide. The one fixed beat
// is the three-direction fork the owner clicks. The owner can answer, ask, or
// interject anytime through the bar at the bottom. When the brain calls the
// deck complete, we hand off to the build lane (vault + graph fill).
window.PlanBrain = (() => {
  let board, opts, state, running = false;
  let bar, askResolve = null, deckNav = null;

  let primed = null;

  // PREFETCH the first question DURING the greeting (which is still playing) so
  // when the greeting ends there is NO LLM wait — only the on-demand synth.
  // planmode calls this as the greeting starts.
  function prime(b, o, pairing) {
    if (board) return;                 // already set up
    board = b; opts = o || {};
    const titles = ((pairing && pairing.slides) || []).map(s => (s.md.match(/^#+\s*(.+)$/m) || [])[1] || "");
    state = {
      form: (pairing && pairing.form) || safeForm(),
      pairing: pairing || {}, history: [], fork_done: false, deck_titles: titles
    };
    primed = postTurn();               // the first /plan/turn fires NOW
  }

  async function take(b, o, pairing) {
    if (!board) prime(b, o, pairing);  // not primed → set up + fetch now
    // the conversation owns the text now: the deck shows content, the pinned
    // bar shows the open question, the voice speaks. Hide the redundant caption.
    document.body.classList.add("pm-convo");
    mountBar();
    running = true;
    loop();
  }

  function safeForm() {
    try { return JSON.parse(sessionStorage.getItem("ap-form") || "{}"); } catch (_) { return {}; }
  }

  // the interjection bar: type OR hold-space to talk (push-to-talk)
  function mountBar() {
    if (bar) return;
    bar = document.createElement("div");
    bar.className = "pm-bar";
    bar.innerHTML = `
      <div id="pm-qpin"></div>
      <div class="pm-bar-row">
        <input id="pm-say" placeholder="type your answer…" autocomplete="off" spellcheck="false">
        <button id="pm-send" class="pm-send" title="send">→</button>
      </div>
      <div class="pm-ptt" id="pm-ptt"></div>`;
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
    wirePTT(input);
    renderKeycap();
    // NOT autofocused — space is push-to-talk once mic is enabled; click to type
  }

  // ── push-to-talk state machine — SINGLE source of truth, infallible ──
  //   micState: "unknown"|"prompt"|"granted"|"denied"  ·  recording: bool
  const ptt = { mic: "unknown", recording: false };
  let _pttHandlers = null, _keycapT = null;

  async function refreshMic() {
    if (!board) return;
    const s = board.micState ? await board.micState() : "prompt";
    if (ptt.mic !== s) { ptt.mic = s; renderKeycap(); }
  }

  // the keycap: enable-badge until mic is granted, then HOLD [space] to talk
  function renderKeycap() {
    const el = bar && bar.querySelector("#pm-ptt");
    if (!el) return;
    if (ptt.mic === "granted") {
      const verb = ptt.recording ? "release to send" : (board && board.isSpeaking && board.isSpeaking() ? "to interrupt" : "to talk");
      el.innerHTML = `<span class="pm-ptt-lead">hold</span><kbd class="pm-key">space</kbd><span class="pm-ptt-verb">${verb}</span>`;
      el.classList.remove("pm-ptt-enable");
      el.onclick = null;
    } else if (ptt.mic === "denied") {
      el.innerHTML = `<span class="pm-ptt-blocked">🎙 mic blocked — allow it in system settings, or just type</span>`;
      el.classList.remove("pm-ptt-enable");
      el.onclick = null;
    } else {
      el.innerHTML = `<button class="pm-enable-mic">🎙 enable voice</button><span class="pm-ptt-lead" style="margin-left:8px">to hold-space talk</span>`;
      el.classList.add("pm-ptt-enable");
      el.onclick = async () => {
        const ok = board && board.enableMic ? await board.enableMic() : false;
        ptt.mic = ok ? "granted" : "denied";
        renderKeycap();
      };
    }
  }

  function wirePTT(input) {
    // live partials land IN THE INPUT (owner: not a bubble, not above — the input)
    const live = t => { if (ptt.recording) { input.value = t; input.classList.add("pm-live-in"); } };

    async function start() {
      if (ptt.recording || ptt.mic !== "granted") return;
      ptt.recording = true;
      bar.classList.add("ptt-live");
      renderKeycap();
      const ok = await board.pttStart(live);
      if (!ok) { ptt.recording = false; bar.classList.remove("ptt-live"); ptt.mic = "denied"; renderKeycap(); }
    }
    async function stop() {
      if (!ptt.recording) return;
      ptt.recording = false;
      bar.classList.remove("ptt-live");
      renderKeycap();
      input.classList.remove("pm-live-in");
      const final = await board.pttStop();
      const text = (final || input.value || "").trim();
      input.value = "";
      if (text) send(text);
    }

    const onDown = e => {
      if (e.code !== "Space" || e.repeat) return;
      if (document.activeElement === input) return;   // typing → space is a space
      if (ptt.mic !== "granted") return;              // not enabled → space does nothing
      e.preventDefault();
      start();
    };
    const onUp = e => {
      if (e.code !== "Space") return;
      if (!ptt.recording) return;
      e.preventDefault();
      stop();
    };
    // FAILSAFE: any focus loss / visibility change while holding → force-stop,
    // so the recorder can never get stuck on (the keyup might never arrive)
    const bail = () => { if (ptt.recording) stop(); };

    window.addEventListener("keydown", onDown, true);
    window.addEventListener("keyup", onUp, true);
    window.addEventListener("blur", bail);
    document.addEventListener("visibilitychange", () => { if (document.hidden) bail(); });
    _pttHandlers = { onDown, onUp, bail };

    // poll mic state + keep the keycap verb (talk/interrupt) live
    refreshMic();
    _keycapT = setInterval(() => { if (ptt.mic === "granted" && !ptt.recording) renderKeycap(); }, 400);
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
    let misses = 0, prefetch = primed;   // the first turn was primed during the greeting
    primed = null;
    while (running && board) {
      // PIPELINE: a prefetched turn (primed during the greeting, or fetched
      // during the previous line's narration) lands with ZERO llm wait. Only a
      // genuinely unpredictable wait (right after the owner answers) shows the
      // thinking cloud — and that's honest, not a mask.
      if (!prefetch && board.think) board.think(true);
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
          deck_titles: state.deck_titles.slice(-12)
        })
      });
      if (!r.ok) return null;
      return await r.json();
    } catch (_) { return null; }
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

    // COMPILE the deck → the real vault (inform7 → inform6): /plan/finalize
    // turns this session's deck into the plan.* contract and builds the first
    // workspace/agents/rules from it — the conversation actually becomes the
    // system. Then the app opens on the first proposal.
    let built = null;
    try {
      const r = await fetch("/plan/finalize", {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify(state.form || {})
      });
      if (r.ok) built = await r.json();
    } catch (_) {}
    if (built && built.workspace) {
      const sub = proc.querySelector(".pm-proc-sub");
      if (sub) sub.textContent = `built ${built.workspace} · ${(built.agents || []).length} agent(s) · ${(built.pages || []).length} pages`;
    }
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

  function ensureChat() {
    let log = document.getElementById("pm-chat");
    if (!log) { log = document.createElement("div"); log.id = "pm-chat"; log.className = "pm-chat"; document.body.appendChild(log); }
    return log;
  }
  function bubble(who, text) {
    const log = ensureChat();
    const b = document.createElement("div");
    b.className = "pm-bub " + (who === "you" ? "you" : "ap");
    b.textContent = text;
    log.appendChild(b);
    while (log.children.length > 4) log.removeChild(log.firstChild);
    setTimeout(() => { b.classList.add("fade"); }, 4200);
  }

  function teardown() {
    running = false;
    document.body.classList.remove("pm-convo");
    if (_pttHandlers) {
      window.removeEventListener("keydown", _pttHandlers.onDown, true);
      window.removeEventListener("keyup", _pttHandlers.onUp, true);
      window.removeEventListener("blur", _pttHandlers.bail);
      _pttHandlers = null;
    }
    clearInterval(_keycapT); _keycapT = null;
    if (ptt.recording && board && board.pttStop) { board.pttStop(); ptt.recording = false; }
    [bar, deckNav, document.getElementById("pm-chat")].forEach(el => el && el.remove());
    bar = null; deckNav = null;
    document.querySelectorAll(".pm-fork,.pm-proc").forEach(el => el.remove());
  }

  const escapeHtml = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const oneLine = md => String(md).replace(/^#+\s*/gm, "").replace(/[`*_>-]/g, "").split("\n").map(x => x.trim()).filter(Boolean).slice(0, 1)[0] || "";

  return { take, teardown };
})();
