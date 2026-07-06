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
    bar.dataset.state = "ready";
    // a TEXTAREA (not a one-line input) so the FULL transcript is visible as it
    // grows — talking or typing. The input is the single surface; no bubble.
    bar.innerHTML = `
      <div id="pm-qpin"></div>
      <div class="pm-bar-row">
        <textarea id="pm-say" placeholder="type your answer…" rows="1" autocomplete="off" spellcheck="false"></textarea>
        <button id="pm-send" class="pm-send" title="send">→</button>
      </div>
      <div class="pm-ptt" id="pm-ptt"></div>`;
    document.body.appendChild(bar);
    const input = bar.querySelector("#pm-say");
    const fire = () => {
      const t = input.value.trim();
      if (!t || composerState === "talking" || composerState === "sending") return;
      send(t);   // send() shows the "sending" state, then the loop clears it
    };
    bar.querySelector("#pm-send").onclick = fire;
    // Enter sends; Shift+Enter is a newline. Typing grows the box + flips state.
    input.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); fire(); } });
    input.addEventListener("input", () => { growTA(input); if (composerState === "ready") bar.dataset.typing = input.value ? "1" : ""; });
    input.addEventListener("focus", () => { if (composerState === "speaking") { /* clicking to type interrupts */ } });
    wirePTT(input);
    renderKeycap();
    // NOT autofocused — space is push-to-talk once mic is enabled; click to type
  }

  // composer state machine: ready → typing → talking(locked) → sending → speaking.
  // Single source of truth; every transition re-locks the field + re-renders the keycap.
  let composerState = "ready", _retryT = null;
  function setComposer(s) {
    composerState = s;
    if (!bar) return;
    bar.dataset.state = s;
    if (s !== "ready") bar.dataset.typing = "";
    const ta = bar.querySelector("#pm-say");
    if (ta) {
      ta.readOnly = (s === "talking" || s === "sending" || s === "speaking");
      ta.classList.toggle("pm-live-in", s === "talking");
      ta.placeholder = s === "sending" ? "sending…" : s === "speaking" ? "" : s === "talking" ? "listening…" : "type your answer…";
      if (ta.readOnly && document.activeElement === ta) ta.blur();   // free space for interrupt-to-talk
      if (s === "ready" || s === "speaking") growTA(ta);
    }
    if (s !== "ready") { clearTimeout(_retryT); bar.dataset.retry = ""; }
    renderKeycap();
  }
  function clearComposer() { const ta = bar && bar.querySelector("#pm-say"); if (ta) { ta.value = ""; growTA(ta); } }
  // PTT ended with nothing usable → a brief "try again" so the owner KNOWS
  function composerRetry() {
    if (!bar) return;
    setComposer("ready");
    bar.dataset.retry = "1";
    renderKeycap();
    clearTimeout(_retryT);
    _retryT = setTimeout(() => { if (bar) { bar.dataset.retry = ""; renderKeycap(); } }, 3000);
  }
  // grow a textarea to fit its content (capped by CSS max-height → then scrolls)
  function growTA(ta) { if (!ta) return; ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 200) + "px"; }

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
      if (bar && bar.dataset.retry) {
        el.innerHTML = `<span class="pm-ptt-retry">didn't catch that — hold <kbd class="pm-key">space</kbd> to try again</span>`;
      } else if (composerState === "sending") {
        el.innerHTML = `<span class="pm-ptt-verb pm-ptt-sending">sending…</span>`;
      } else {
        const verb = ptt.recording ? "release to send" : (board && board.isSpeaking && board.isSpeaking() ? "to interrupt" : "to talk");
        el.innerHTML = `<span class="pm-ptt-lead">hold</span><kbd class="pm-key">space</kbd><span class="pm-ptt-verb">${verb}</span>`;
      }
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
    // live partials land IN THE INPUT and GROW it, so the FULL transcript is
    // visible as they speak (owner: in the input, not a bubble, not above)
    const live = t => { if (ptt.recording) { input.value = t; growTA(input); } };

    async function start() {
      if (ptt.recording || ptt.mic !== "granted") return;
      ptt.recording = true;
      input.value = "";                       // fresh transcript
      setComposer("talking");                 // locked, live, "release to send"
      const ok = await board.pttStart(live);
      if (!ok) { ptt.recording = false; ptt.mic = "denied"; setComposer("ready"); }
    }
    async function stop() {
      if (!ptt.recording) return;
      ptt.recording = false;
      setComposer("sending");                 // acknowledge the hold ended → processing
      const final = await board.pttStop();
      const text = (final || input.value || "").trim();
      if (text) { input.value = text; growTA(input); send(text); }
      else composerRetry();                   // nothing captured → "didn't catch that"
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

  // owner speaks → into history; if the brain was waiting on an answer, release.
  // No bubble — the input already showed it; the "sending" state confirms it left.
  function send(text) {
    state.history.push({ role: "user", content: text });
    setComposer("sending");
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

      // SEARCH move: the agent looks something up on the real web (Nexus.Browse).
      // Say the "checking" line, show the searching bubble, then feed results
      // back into history so the NEXT turn uses them.
      if (move.move === "search") {
        state.history.push({ role: "assistant", content: move.say });
        setComposer("speaking"); clearComposer();
        if (move.say) { if (board.warm) board.warm(move.say); await board.say(move.say); }
        if (board.think) board.think(true, "searching the web…");
        const summary = await postSearch(move.query);
        if (board.think) board.think(false);
        state.history.push({ role: "system",
          content: `WEB SEARCH RESULTS for "${move.query}" (use these to inform your next move; cite naturally, don't dump):\n${summary}` });
        continue;
      }

      // BASH move: the agent's full shell — read a skill, grep docs, search/scrape.
      // The thought bubble reflects what it's doing; stdout feeds back next turn.
      if (move.move === "bash") {
        state.history.push({ role: "assistant", content: move.say });
        setComposer("speaking"); clearComposer();
        if (move.say) { if (board.warm) board.warm(move.say); await board.say(move.say); }
        if (board.think) board.think(true, bashLabel(move.cmd));
        const out = await postBash(move.cmd);
        if (board.think) board.think(false);
        state.history.push({ role: "system", content: `$ ${move.cmd}\n${out}` });
        continue;
      }

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
      // the AP is now responding → lock the composer + clear the consumed answer
      setComposer("speaking"); clearComposer();
      await board.say(move.say);       // resolves when narration ends

      if (move.move === "ask") {
        setComposer("ready");          // open for the owner's answer
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

  // run the agent's web search through the Nexus browser, return a compact
  // numbered digest the brain can read on its next turn
  async function postSearch(query) {
    try {
      const r = await fetch("/plan/search", {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify({ query })
      });
      if (!r.ok) return "(search unavailable)";
      const d = await r.json();
      if (!d.results || !d.results.length) return "(no results found)";
      return d.results.map((x, i) => `${i + 1}. ${x.title || ""} — ${(x.snippet || "").slice(0, 200)} [${x.url || ""}]`).join("\n");
    } catch (_) { return "(search failed)"; }
  }

  // run one agent bash line through the Nexus shell (files/skills/web), return stdout
  async function postBash(cmd) {
    try {
      const r = await fetch("/plan/bash", {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify({ command: cmd })
      });
      if (!r.ok) return "(tool unavailable)";
      const d = await r.json();
      return (d.output || "").slice(0, 3000) || "(no output)";
    } catch (_) { return "(tool failed)"; }
  }
  // label the thought bubble by what the command is doing
  function bashLabel(cmd) {
    cmd = (cmd || "").trim();
    if (/^(search|scrape|render|screenshot|fetch|navigate)\b/.test(cmd)) return "searching the web…";
    if (/skills?\//.test(cmd) || /\bskill--/.test(cmd)) return "reading a skill…";
    if (/^(ls|cat|grep|head|tail)\b/.test(cmd)) return "checking my notes…";
    return "thinking…";
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
