// ══ VoiceStage — the local speech-to-speech call stage for the autopoet app ══
//
// When a voice call starts, the graph canvas becomes a WHITEBOARD: the D3
// graph fades out, grid paper stays, and the cube avatar (extruded squircle,
// toon outline, bean hands) floats freely on it — talking with local Kokoro
// TTS (WebGPU worker), hearing you through Silero VAD + the app's local
// /voice/dictate STT, thinking through /voice/brain (Groq), and drawing
// D2 diagrams live via /voice/d2. When the call ends, the whiteboard fades
// and the graph returns. That state transition is this module's contract:
//
//   VoiceStage.enter({ token, stage, callbar, callin })   call starts
//   VoiceStage.exit()                                     call ends
//   VoiceStage.ask(text)                                  typed turn
//
// Faces: the avatar carries its own mouth/brow/viseme library (vs-ap-* ids;
// the graph face's #ap-* ids are untouched). The mouth is AUDIO-DRIVEN while
// Kokoro speaks (analyser amplitude gates the jaw, the current word's vowel
// family picks the shape); the text cycler is the no-audio fallback. The
// listener NLP reacts to YOUR transcript before the brain answers, and the
// brain's [mood]/[point]/[+reveal] cues drive the performance.
//
// Accessibility: one single-line caption (blue = your words via Moonshine,
// ink = the avatar speaking, karaoke word) + a full-transcript drawer in
// large type, toggled from the call bar (replaces the small text input).
(function () {
  "use strict";

  // ────────────────────────── module state ──────────────────────────
  var TOKEN = "";
  var stageEl = null, callbarEl = null, callinEl = null;
  var root = null, mounted = false;
  var timers = [], listeners = [];
  var transcript = [];   // [{who:"you"|"poet", text}]

  function later(t) { timers.push(t); return t; }
  function listen(el, ev, fn, opts) { el.addEventListener(ev, fn, opts); listeners.push([el, ev, fn]); }
  function clearAll() {
    timers.forEach(function (t) { clearTimeout(t); clearInterval(t); });
    timers = [];
    listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2]); });
    listeners = [];
  }

  // ────────────────────────── styles (injected once) ──────────────────────────
  var CSS = [
    "#vs-root { position:absolute; inset:0; z-index:6; opacity:0; transition:opacity .45s ease; }",
    "#vs-root.on { opacity:1; }",
    "#vs-root .vs-paper { position:absolute; inset:0; background:var(--paper,#fff);",
    "  background-image:linear-gradient(var(--grid,rgba(18,19,22,.07)) 1px, transparent 1px),",
    "  linear-gradient(90deg, var(--grid,rgba(18,19,22,.07)) 1px, transparent 1px);",
    "  background-size:24px 24px; }",
    "#vs-graph-bg { position:absolute; left:50%; top:40%; transform:translate(-50%,-50%);",
    "  width:min(86%,1080px); pointer-events:none; opacity:0; transition:opacity .5s ease-out; }",
    "#vs-graph-bg.on { opacity:1; }",
    "#vs-graph-bg svg { width:100%; height:auto; display:block; }",
    "#vs-graph-bg .shape rect, #vs-graph-bg .shape path { fill:#fff; stroke:#121316; stroke-width:1.3; }",
    "#vs-graph-bg text { fill:#121316 !important; font-family:ui-monospace,Menlo,monospace !important; font-size:15px !important; }",
    "#vs-graph-bg path.connection { stroke:rgba(18,19,22,.38) !important; }",
    "#vs-graph-bg marker path, #vs-graph-bg marker polygon { fill:rgba(18,19,22,.38); stroke:rgba(18,19,22,.38); }",
    "#vs-graph-bg .m-hidden { opacity:0 !important; }",
    "#vs-graph-bg .m-pop { animation:vs-mpop .45s cubic-bezier(.34,1.5,.4,1) both; transform-box:fill-box; transform-origin:center; }",
    "@keyframes vs-mpop { from { opacity:0; transform:scale(.55);} to { opacity:1; transform:scale(1);} }",
    "#vs-graph-bg .m-fade { animation:vs-mfade .5s ease-out both; }",
    "@keyframes vs-mfade { from { opacity:0; } to { opacity:1; } }",
    "#vs-stagebox { position:absolute; inset:0; display:grid; place-items:center; pointer-events:none; }",
    "#vs-scene { width:132px; height:132px; pointer-events:auto; --toon:1.6px;",
    "  filter:drop-shadow(var(--toon) 0 0 #121316) drop-shadow(calc(-1*var(--toon)) 0 0 #121316)",
    "  drop-shadow(0 var(--toon) 0 #121316) drop-shadow(0 calc(-1*var(--toon)) 0 #121316)",
    "  drop-shadow(0 16px 26px rgba(18,19,22,.04));",
    "  transform:translate(var(--sx,0px), var(--sy,0px)) scale(var(--sc,1));",
    "  transition:transform .8s cubic-bezier(.3,1,.35,1); }",
    "#vs-cube { width:100%; height:100%; position:relative; transform-style:preserve-3d;",
    "  transform:rotateX(calc(var(--rx,0deg) + var(--nod,0deg) + var(--br,0deg))) rotateY(var(--ry,0deg)) rotateZ(var(--rz,0deg));",
    "  transition:transform .12s ease-out; cursor:pointer; }",
    "#vs-cube .vs-layer { position:absolute; inset:0; border-radius:35px; }",
    "#vs-cube .vs-face-layer { background:#fff; display:grid; place-items:center; }",
    ".vs-face-layer svg { display:block; width:100%; height:100%; }",
    ".vs-hand { position:absolute; left:0; top:0; width:30px; height:40px; pointer-events:none;",
    "  opacity:var(--po,0); transform-origin:15px 20px;",
    "  transform:translate(var(--hx,51px), var(--hy,120px)) translateZ(67px) rotate(var(--hr,0deg)) scale(var(--hs,0));",
    "  transition:transform .3s cubic-bezier(.34,1.45,.4,1), opacity .18s ease-out; }",
    ".vs-hand svg { width:100%; height:100%; display:block; }",
    ".vs-hand.left svg { transform:scaleX(-1); }",
    "#vs-ref-overlay { position:fixed; inset:0; pointer-events:none; z-index:8; }",
    "#vs-ref-overlay path { fill:none; stroke:rgba(18,19,22,.45); stroke-width:2; stroke-linecap:round;",
    "  stroke-dasharray:5 6; animation:vs-ants .6s linear infinite; }",
    "@keyframes vs-ants { to { stroke-dashoffset:-11; } }",
    // single-line caption above the call bar — recolored by speaker
    "#vs-caption { position:absolute; bottom:76px; left:50%; transform:translateX(-50%);",
    "  max-width:min(720px,80%); background:#fff; border:1px solid var(--line,rgba(18,19,22,.14));",
    "  border-radius:13px; padding:9px 16px; box-shadow:0 10px 30px rgba(25,35,55,.14);",
    "  font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; text-align:center;",
    "  white-space:nowrap; overflow:hidden; text-overflow:ellipsis; z-index:9;",
    "  color:rgba(18,19,22,.30); display:none; }",
    "#vs-caption.on { display:block; }",
    "#vs-caption .said { color:#121316; }",
    "#vs-caption .word-now { color:#121316; font-weight:700; }",
    "#vs-caption.you { color:#2b6ca3; border-color:rgba(43,108,163,.4); }",
    "#vs-caption.you::before { content:'you: '; opacity:.55; font-weight:600; }",
    "#vs-caption.dim { color:rgba(18,19,22,.35); font-style:italic; }",
    // full-transcript drawer (ADA: large type, whole conversation)
    "#vs-drawer { position:absolute; top:12px; right:14px; bottom:76px; width:min(420px,44%);",
    "  background:#fff; border:1px solid var(--line,rgba(18,19,22,.14)); border-radius:14px;",
    "  box-shadow:0 14px 40px rgba(25,35,55,.16); z-index:9; display:none; flex-direction:column; }",
    "#vs-drawer.on { display:flex; }",
    "#vs-drawer .hd { display:flex; align-items:center; justify-content:space-between;",
    "  padding:12px 16px; border-bottom:1px solid var(--line,rgba(18,19,22,.1));",
    "  font:700 11px ui-monospace,monospace; letter-spacing:.08em; text-transform:uppercase; color:rgba(18,19,22,.5); }",
    "#vs-drawer .hd button { border:none; background:none; cursor:pointer; font-size:16px; color:rgba(18,19,22,.5); }",
    "#vs-drawer-log { flex:1; overflow-y:auto; padding:14px 16px; display:flex; flex-direction:column; gap:12px; }",
    "#vs-drawer-log .ln { font:17px/1.55 -apple-system,BlinkMacSystemFont,sans-serif; color:#121316; }",
    "#vs-drawer-log .ln b { display:block; font:700 10.5px ui-monospace,monospace; letter-spacing:.07em;",
    "  text-transform:uppercase; margin-bottom:2px; }",
    "#vs-drawer-log .ln.you b { color:#2b6ca3; } #vs-drawer-log .ln.poet b { color:rgba(18,19,22,.55); }",
    "#vs-drawer-log .ln.you { color:#274e6d; }",
    "#vs-drawer .ft { padding:10px; border-top:1px solid var(--line,rgba(18,19,22,.1)); }",
    "#vs-drawer-in { width:100%; border:1px solid var(--line,rgba(18,19,22,.16)); border-radius:9px;",
    "  padding:9px 12px; font:15px -apple-system,BlinkMacSystemFont,sans-serif; outline:none; }",
    "#vs-drawer-in:focus { border-color:#121316; }",
    // transcript button dropped into the call bar — the double-id selector
    // outguns the app's generic `#callbar button` circle rule (36px/50%)
    "#callbar #vs-tbtn { border:none; border-radius:999px; width:auto; height:36px; padding:0 14px;",
    "  cursor:pointer; display:flex; align-items:center; gap:7px; color:#e8eaf0; background:#343a42;",
    "  font:12px -apple-system,BlinkMacSystemFont,sans-serif; }",
    "#callbar #vs-tbtn:hover { background:#454c56; }",
    "#callbar #vs-tbtn svg { width:14px; height:14px; flex:none; }",
    "#callbar #vs-tbtn span { white-space:nowrap; }",
    // the D3 graph fades while the whiteboard is up
    "#stage.vs-whiteboard > svg#graph { opacity:0; transition:opacity .45s ease; }",
    "#stage.vs-whiteboard #callcaption { display:none; }"
  ].join("\n");

  function injectCSS() {
    if (document.getElementById("vs-style")) return;
    var s = document.createElement("style");
    s.id = "vs-style";
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  // ────────────────────────── face library ──────────────────────────
  var MOUTHS = {
    neutral: '<path d="m35.05 46.19-.5.03c-1.29.07-1.3 2.04 0 2l13.82-.4c1.28-.03 1.29-2.03 0-2l-13.83.4v2l.5-.03c1.29-.07 1.3-2.07 0-2" fill="#121316"/>',
    happy: '<path d="M27.86 43.79c2.41 9.29 15.16 12.28 22.34 6.67a14 14 0 0 0 4.7-7.22c.36-1.24-1.57-1.77-1.93-.53-1.24 4.23-4.33 7.39-8.68 8.33-3.77.8-8.03-.1-11.05-2.52a10 10 0 0 1-3.45-5.26c-.34-1.25-2.27-.72-1.95.53" fill="#121316"/>',
    grin: '<path d="M30.5 44.5 Q40 56.5 49.5 44.5 Q40 48.5 30.5 44.5 Z" fill="#121316" stroke="#121316" stroke-width="1.6" stroke-linejoin="round"/>',
    smirk: '<path d="M33.5 48.5 Q41 52 47.5 45.5" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
    surprised: '<ellipse cx="40" cy="48" rx="3.2" ry="4" stroke="#121316" stroke-width="2" fill="none"/>',
    hopeful: '<path d="M35.7 42.4c-1.18 1.26-2.17 2.74-2.36 4.5a4.4 4.4 0 0 0 1.78 4.02c1.26.9 2.88.8 4.07-.13a5.5 5.5 0 0 0 1.87-3.88c.1-.97-1.46-1.38-1.86-.5-.75 1.63.16 3.26 1.34 4.42a3.9 3.9 0 0 0 4.13.98 4.6 4.6 0 0 0 2.93-3.14 6.6 6.6 0 0 0-.82-4.87c-.64-1.11-2.37-.11-1.73 1 .92 1.6 1.18 4-.7 5.02-.7.35-1.5.36-2.12-.12-.49-.39-1.63-1.55-1.3-2.26l-1.86-.5c-.14 1.34-1.44 3.63-2.97 2.23-1.74-1.59-.22-4 1.03-5.33.88-.94-.53-2.36-1.4-1.4z" fill="#121316"/>'
  };
  var VISEMES = {
    A: '<path d="M33.5 48.5 h13" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
    B: '<rect x="33" y="46.2" width="14" height="4.6" rx="2.3" stroke="#121316" stroke-width="1.8" fill="none"/><path d="M34.5 48.5 h11" stroke="#121316" stroke-width="1.2"/>',
    C: '<ellipse cx="40" cy="48.8" rx="4.8" ry="3.2" fill="#121316"/>',
    D: '<ellipse cx="40" cy="49.2" rx="6.4" ry="5.2" fill="#121316"/>',
    E: '<circle cx="40" cy="48.8" r="3.6" fill="#121316"/>',
    F: '<circle cx="40" cy="48.6" r="2.2" fill="#121316"/>',
    G: '<path d="M34 49.6 h12" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/><path d="M36.5 46.9 v2.4 M40 46.9 v2.4 M43.5 46.9 v2.4" stroke="#121316" stroke-width="1.4" stroke-linecap="round" fill="none"/>',
    H: '<ellipse cx="40" cy="48.8" rx="4.6" ry="3.6" stroke="#121316" stroke-width="1.8" fill="none"/><path d="M37.8 50.6 Q40 46.9 42.2 50.6" stroke="#121316" stroke-width="1.6" stroke-linecap="round" fill="none"/>',
    X: '<path d="M35.5 48.5 h9" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>'
  };
  var BROWS = {
    none: '',
    raised: '<path d="M28.5 30.5 Q31 28.2 33.5 30.5 M46.5 30.5 Q49 28.2 51.5 30.5" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
    worried: '<path d="M28.5 31.8 L33.5 29.2 M46.5 29.2 L51.5 31.8" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
    skeptical: '<path d="M28 29.5 Q31 27.3 34 29.5 M46.5 31.5 h5" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>'
  };
  var HS = 'fill="#fff" stroke="rgba(18,19,22,.16)"';
  var POSES = {
    point: '<svg viewBox="0 0 30 40" fill="none"><path d="M15 2.5 C19.4 2.5 22.5 6 22.5 11 L22.5 24 C22.5 32 19.4 37.5 15 37.5 C10.6 37.5 7.5 32 7.5 24 L7.5 11 C7.5 6 10.6 2.5 15 2.5 Z" ' + HS + ' stroke-width="1.4"/><ellipse cx="24" cy="26" rx="4.4" ry="6" ' + HS + ' stroke-width="1.4"/></svg>',
    open: '<svg viewBox="0 0 30 40" fill="none"><rect x="6.5" y="15" width="19" height="19" rx="8.5" ' + HS + ' stroke-width="1.4"/><rect x="7" y="3.5" width="5.4" height="15" rx="2.7" ' + HS + ' stroke-width="1.3"/><rect x="13.2" y="1.5" width="5.4" height="17" rx="2.7" ' + HS + ' stroke-width="1.3"/><rect x="19.4" y="3.5" width="5.4" height="15" rx="2.7" ' + HS + ' stroke-width="1.3"/><ellipse cx="27.2" cy="24.5" rx="3.6" ry="5.2" ' + HS + ' stroke-width="1.3"/></svg>',
    thumb: '<svg viewBox="0 0 30 40" fill="none"><rect x="6" y="16" width="17.5" height="16.5" rx="7.5" ' + HS + ' stroke-width="1.4"/><rect x="5.8" y="3" width="6.4" height="16" rx="3.2" transform="rotate(-9 9 11)" ' + HS + ' stroke-width="1.4"/></svg>'
  };

  var FACE_SVG =
    '<svg viewBox="0 0 80 80" fill="none" preserveAspectRatio="xMidYMid meet">' +
    '<g id="vs-ap-face" style="transition:transform .12s ease-out">' +
    '<g id="vs-ap-brows"></g>' +
    '<g id="vs-ap-eyes-px" style="transition:transform .12s ease-out">' +
    '<g id="vs-ap-eyes-open"><path d="M29.8 36.53v4.54c0 .52.46 1.02 1 1s1-.44 1-1V36.4c0-.52-.46-1.02-1-1s-1 .44-1 1M49.2 36l-.15 4.81a1 1 0 0 0 1 1c.56-.02.98-.44 1-1l.15-4.8a1 1 0 0 0-1-1 1 1 0 0 0-1 1" fill="#121316"/></g>' +
    '<g id="vs-ap-eyes-closed" display="none"><path d="M28.9 38.9h3.9a1 1 0 0 1 0 2h-3.9a1 1 0 0 1 0-2M48.3 38.9h3.9a1 1 0 0 1 0 2h-3.9a1 1 0 0 1 0-2" fill="#121316"/></g>' +
    '</g><g id="vs-ap-mouth" transform="translate(0 2)"></g></g></svg>';

  // ────────────────────────── face runtime ──────────────────────────
  var mood = "neutral", squintRestore = null;
  var facePrefix = "vs-ap-";   // "ap-" when adopting the app's primary face
  function el(s) { return document.getElementById(facePrefix + s); }
  function setMouth(k) { var m = el("mouth"), svg = MOUTHS[k] || VISEMES[k]; if (m && svg !== undefined) m.innerHTML = svg; }
  function setBrows(k) { var b = el("brows"); if (b && BROWS[k] !== undefined) b.innerHTML = BROWS[k]; }
  function setEyes(open) {
    var o = el("eyes-open"), c = el("eyes-closed");
    if (o) o.setAttribute("display", open ? "inline" : "none");
    if (c) c.setAttribute("display", open ? "none" : "inline");
  }
  function startBlink() {
    if (adopt) return;   // the adopted face already blinks (createFace's loop)
    (function blink() {
      if (!mounted) return;
      if (el("eyes-open")) { setEyes(false); later(setTimeout(function () { setEyes(true); }, 110)); }
      later(setTimeout(blink, 3000 + Math.random() * 3000));
    })();
  }

  // audio-driven mouth: amplitude gates the jaw, word vowels pick the family
  var actx = null, analyser = null, lastSrc = null, audioDriven = false;
  var curFamily = "wide", mouthRaf = null, env = 0, zeroCheck = { sum: 0 };
  var FAM = { open: ["C", "D"], wide: ["B", "C"], round: ["F", "E"] };
  function familyOf(word) {
    var w = String(word).toLowerCase(), c = { open: 0, wide: 0, round: 0 };
    for (var i = 0; i < w.length; i++) {
      var ch = w[i];
      if (ch === "a") c.open++;
      else if (ch === "e" || ch === "i" || ch === "y") c.wide++;
      else if (ch === "o" || ch === "u" || ch === "w") c.round++;
    }
    var best = "wide", n = 0;
    Object.keys(c).forEach(function (k) { if (c[k] > n) { n = c[k]; best = k; } });
    return best;
  }
  function attachAnalyser(a) {
    try {
      if (!actx) {
        actx = new (window.AudioContext || window.webkitAudioContext)();
        analyser = actx.createAnalyser();
        analyser.fftSize = 512;
        analyser.connect(actx.destination);
      }
      if (actx.state === "suspended") actx.resume();
      if (lastSrc) { try { lastSrc.disconnect(); } catch (e) {} }
      lastSrc = actx.createMediaElementSource(a);
      lastSrc.connect(analyser);
      audioDriven = true;
      env = 0; zeroCheck = { sum: 0 };
      startMouthLoop();
    } catch (e) { audioDriven = false; }
  }
  function startMouthLoop() {
    if (mouthRaf) return;
    var data = new Uint8Array(analyser.fftSize), lastShape = "";
    (function frame() {
      mouthRaf = requestAnimationFrame(frame);
      if (!mounted || !playing) { cancelAnimationFrame(mouthRaf); mouthRaf = null; return; }
      if (!audioClip || audioClip.paused || !audioDriven) return;
      analyser.getByteTimeDomainData(data);
      var s = 0;
      for (var i = 0; i < data.length; i++) { var v = (data[i] - 128) / 128; s += v * v; }
      var rms = Math.sqrt(s / data.length);
      env = Math.max(rms, env * 0.82);
      zeroCheck.sum += rms;
      if (audioClip.currentTime > 0.6 && zeroCheck.sum < 0.01) { audioDriven = false; return; }
      var shape;
      if (env < 0.03) shape = "X";
      else if (env < 0.075) shape = FAM[curFamily][0];
      else shape = FAM[curFamily][1];
      if (shape !== lastShape) { lastShape = shape; setMouth(shape); }
    })();
  }
  var talkT = null;
  function talkWord(word) {
    if (audioDriven) { curFamily = familyOf(word); return; }
    clearInterval(talkT);
    var V = { a: "D", e: "C", i: "B", y: "B", o: "E", u: "F", w: "F", m: "A", b: "A", p: "A", f: "G", v: "G", l: "H" };
    var frames = [];
    String(word).toLowerCase().split("").forEach(function (c) { if (/[a-z]/.test(c)) frames.push(V[c] || "B"); });
    frames.push("X");
    var j = 0;
    talkT = later(setInterval(function () {
      if (j >= frames.length) { clearInterval(talkT); setMouth(mood); return; }
      setMouth(frames[j++]);
    }, 60));
  }

  // ────────────────────────── cube body + gaze ──────────────────────────
  var cube = null, scene = null, faceMount = null;
  var setAttention = function () {};
  function buildCube() {
    var SIZE = 132, STEP = 3, half = SIZE / 2;
    for (var z = half - STEP; z >= -half; z -= STEP) {
      var t = (half - z) / SIZE, k = Math.pow(t, 0.75);
      var rg = Math.round(255 - k * 48), b = Math.round(255 - k * 55);
      var d = document.createElement("div");
      d.className = "vs-layer";
      d.style.background = "rgb(" + rg + "," + rg + "," + b + ")";
      d.style.transform = "translateZ(" + z + "px)";
      cube.insertBefore(d, faceMount);
    }
    faceMount.style.transform = "translateZ(" + half + "px)";
  }
  function gesture(prop, seq, ms) {
    var i = 0;
    (function step() {
      if (!mounted) return;
      cube.style.setProperty(prop, seq[i] + "deg");
      if (++i < seq.length) later(setTimeout(step, ms));
    })();
  }
  function nod() { gesture("--nod", [6, -2, 5, 0], 130); }
  function startGaze() {
    var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) return;
    var tx = 0, ty = 0, cursorWant = { x: 0, y: 0 }, raf = null;
    var attention = null, attnPri = 0, attnUntil = 0;
    var clamp1 = function (v) { return Math.max(-1, Math.min(1, v)); };
    setAttention = function (pt, ms, pri) {
      var now = performance.now();
      if (pt && attention && now < attnUntil && (pri || 1) < attnPri) return;
      attention = pt; attnPri = pri || 1; attnUntil = now + (ms || 700);
      kick();
    };
    var kick = function () { if (!raf) raf = requestAnimationFrame(apply); };
    listen(window, "mousemove", function (e) {
      if (!mounted) return;
      var r = faceMount.getBoundingClientRect(); if (!r.width) return;
      cursorWant = { x: clamp1((e.clientX - (r.left + r.width / 2)) / (innerWidth * 0.5)),
                     y: clamp1((e.clientY - (r.top + r.height / 2)) / (innerHeight * 0.5)) };
      kick();
    }, { passive: true });
    var apply = function () {
      raf = null;
      if (!mounted) return;
      var f = el("face"), px = el("eyes-px"); if (!f || !px) return;
      if (attention && performance.now() > attnUntil) attention = null;
      var want;
      if (attention) {
        var C = stageCenter();
        want = { x: clamp1((attention.x - C.x) / (innerWidth * 0.45)),
                 y: clamp1((attention.y - C.y) / (innerHeight * 0.45)) };
      } else if (playing) want = { x: 0, y: 0 };
      else want = cursorWant;
      tx += (want.x - tx) * 0.22; ty += (want.y - ty) * 0.22;
      f.setAttribute("transform", "translate(" + (tx * 2.2).toFixed(2) + " " + (ty * 2.2).toFixed(2) + ") skewX(" + (-tx * 1.8).toFixed(2) + ") skewY(" + (ty * 1.0).toFixed(2) + ")");
      px.setAttribute("transform", "translate(" + (tx * 0.8).toFixed(2) + " " + (ty * 0.8).toFixed(2) + ")");
      cube.style.setProperty("--ry", (tx * 8).toFixed(2) + "deg");
      cube.style.setProperty("--rx", (-ty * 8).toFixed(2) + "deg");
      if (Math.abs(want.x - tx) > 0.005 || Math.abs(want.y - ty) > 0.005 || playing || attention) raf = requestAnimationFrame(apply);
    };
    // breathing
    var bt = 0;
    later(setInterval(function () {
      if (!mounted) return;
      bt += 0.09;
      cube.style.setProperty("--br", (Math.sin(bt * 2 * Math.PI / 4.0) * 0.7).toFixed(2) + "deg");
    }, 90));
  }

  // ────────────────────────── hands + skeleton ──────────────────────────
  var overlay = null, hands = null;
  var HALF = 66, REACH = 34, TIP = 17, D = Math.PI / 180, SEC = 30 * D;
  function setPose(h, pose) { if (h.dataset.pose !== pose) { h.dataset.pose = pose; h.innerHTML = POSES[pose]; } }
  function setHand(h, vars) { Object.keys(vars).forEach(function (k) { h.style.setProperty("--" + k, vars[k]); }); }
  function placeHand(side, ang, rotDeg, pose) {
    var hand = hands[side];
    setPose(hand, pose);
    var hx = 66 + Math.cos(ang) * (HALF + REACH) - 15;
    var hy = 66 + Math.sin(ang) * (HALF + REACH) - 20;
    var arm = ang / D + 90;
    rotDeg = rotDeg + 360 * Math.round((arm - rotDeg) / 360);
    var rot = Math.max(arm - 55, Math.min(arm + 55, rotDeg));
    hand._rot = rot;
    setHand(hand, { hx: hx + "px", hy: hy + "px", hr: rot + "deg", hs: 1, po: 1 });
    return rot;
  }
  var edgeRaf = null, waveTimer = null, gestTimer = null;
  function hideHands() {
    if (!hands) return;
    setHand(hands.r, { po: 0, hs: 0 });
    setHand(hands.l, { po: 0, hs: 0 });
    overlay.innerHTML = "";
    clearInterval(waveTimer);
    cancelAnimationFrame(edgeRaf);
    clearTimeout(pointAt._t);
  }
  function hold(ms) { clearTimeout(gestTimer); gestTimer = later(setTimeout(hideHands, ms)); }
  function walkTo(T) {
    var C = stageCenter();
    var dx = T.x - C.x, dy = T.y - C.y;
    var side = dx >= 0 ? "r" : "l";
    var rel = side === "r" ? Math.atan2(dy, dx) : Math.atan2(dy, -dx);
    if (Math.abs(rel) <= SEC && Math.hypot(dx, dy) >= 180) return 0;
    var a = Math.max(-SEC, Math.min(SEC, rel));
    var world = side === "r" ? a : Math.PI - a;
    var L = 300;
    var R = stageEl.getBoundingClientRect();
    var nx = T.x - Math.cos(world) * L, ny = T.y - Math.sin(world) * L;
    if (side === "r" && nx < R.left + 150) { world = Math.PI - a; nx = T.x - Math.cos(world) * L; }
    else if (side === "l" && nx > R.right - 150) { world = a; nx = T.x - Math.cos(world) * L; }
    nx = Math.max(R.left + 150, Math.min(R.right - 150, nx));
    ny = Math.max(R.top + 160, Math.min(R.bottom - 180, ny));
    return moveTo(nx - (R.left + R.width / 2), ny - (R.top + R.height / 2));
  }
  function liveEdge(side, targetEl, ms) {
    var t0 = performance.now();
    cancelAnimationFrame(edgeRaf);
    (function frame() {
      if (!mounted) return;
      var hand = hands[side];
      var hr = hand.getBoundingClientRect();
      if (hr.width) {
        var cx = hr.left + hr.width / 2, cy = hr.top + hr.height / 2;
        var rot = (hand._rot || 0) * D;
        var sc = hr.height / 44;
        var tip = { x: cx + Math.sin(rot) * TIP * sc, y: cy - Math.cos(rot) * TIP * sc };
        var r = targetEl.getBoundingClientRect();
        var T = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        var t2 = { x: cx < r.left ? r.left - 6 : cx > r.right ? r.right + 6 : T.x, y: T.y };
        var len = Math.hypot(t2.x - tip.x, t2.y - tip.y) || 1;
        var ux = (t2.x - tip.x) / len, uy = (t2.y - tip.y) / len;
        var mx = (tip.x + t2.x) / 2, my = (tip.y + t2.y) / 2;
        var bow = Math.min(26, len * 0.12);
        overlay.innerHTML = '<path d="M' + tip.x.toFixed(1) + " " + tip.y.toFixed(1) +
          " Q" + (mx - uy * bow).toFixed(1) + " " + (my + ux * bow).toFixed(1) +
          " " + t2.x.toFixed(1) + " " + t2.y.toFixed(1) + '"/>';
      }
      if (performance.now() - t0 < ms) edgeRaf = requestAnimationFrame(frame);
      else hideHands();
    })();
  }
  function pointAt(elTarget, holdMs) {
    var r = elTarget.getBoundingClientRect();
    var T = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    var hold2 = holdMs || 2400;
    var travel = walkTo(T);
    setAttention(T, travel + hold2, 2);
    var doPlace = function () {
      var C = stageCenter();
      var dx = T.x - C.x, dy = T.y - C.y;
      var side = dx >= 0 ? "r" : "l";
      setHand(hands[side === "r" ? "l" : "r"], { po: 0, hs: 0 });
      var ang = side === "r"
        ? Math.max(-SEC, Math.min(SEC, Math.atan2(dy, dx)))
        : Math.PI - Math.max(-SEC, Math.min(SEC, Math.atan2(dy, -dx)));
      placeHand(side, ang, Math.atan2(dy, dx) / D + 90, "point");
      liveEdge(side, elTarget, hold2);
    };
    clearTimeout(pointAt._t);
    if (travel > 80) pointAt._t = later(setTimeout(doPlace, travel + 60));
    else doPlace();
  }
  function wave(both) {
    hideHands();
    var rBase = placeHand("r", -SEC, 30, "open");
    var lBase = both ? placeHand("l", Math.PI + SEC, 330, "open") : null;
    var flip = false, n = 0;
    waveTimer = later(setInterval(function () {
      flip = !flip;
      setHand(hands.r, { hr: (rBase + (flip ? 16 : -16)) + "deg" });
      if (both) setHand(hands.l, { hr: (lBase + (flip ? -16 : 16)) + "deg" });
      if (++n > 7) hideHands();
    }, 170));
  }
  function thumbsUp() {
    hideHands();
    placeHand("r", -SEC, 8, "thumb");
    setHand(hands.r, { hs: 1.15 });
    later(setTimeout(function () { setHand(hands.r, { hs: 1 }); }, 220));
    hold(1500);
  }
  function shrug() {
    hideHands();
    placeHand("r", 8 * D, 140, "open");
    placeHand("l", 172 * D, 230, "open");
    gesture("--rz", [-3, 3, 0], 200);
    hold(1200);
  }

  // ────────────────────────── D2 graph layer ──────────────────────────
  var graphBg = null, pieces = { nodes: {}, edges: {} };
  function mountGraphSVG(svgText) {
    graphBg.innerHTML = svgText;
    graphBg.classList.add("on");
    var svg = graphBg.querySelector("svg");
    if (svg) { svg.removeAttribute("width"); svg.removeAttribute("height"); svg.style.width = "100%"; svg.style.height = "auto"; }
    graphBg.querySelectorAll("rect").forEach(function (r) {
      var cls = r.getAttribute("class") || "";
      var fill = (r.getAttribute("fill") || "").toUpperCase();
      if (/fill-N7\b/.test(cls) || fill === "#FFFFFF" || fill === "#FFF") r.remove();
    });
    pieces = { nodes: {}, edges: {} };
    graphBg.querySelectorAll("g[class]").forEach(function (g) {
      var cls = g.getAttribute("class") || "";
      if (cls === "shape" || cls.indexOf(" ") > -1) return;
      var name;
      try { name = atob(cls); } catch (e) { return; }
      if (/^\(.+ -&gt; .+\)\[\d+\]$/.test(name)) {
        var em = name.match(/^\((.+) -&gt; (.+)\)\[\d+\]$/);
        pieces.edges[em[1] + "->" + em[2]] = g;
      } else pieces.nodes[name] = g;
      g.classList.add("m-hidden");
    });
  }
  function reveal(spec) {
    spec = spec.replace(/\s+/g, "");
    if (spec.indexOf("->") > -1) {
      var g = pieces.edges[spec];
      if (g) { g.classList.remove("m-hidden"); g.classList.add("m-fade"); }
    } else {
      var n = pieces.nodes[spec];
      if (n) {
        n.classList.remove("m-hidden"); n.classList.add("m-pop");
        var r = n.getBoundingClientRect();
        setAttention({ x: r.left + r.width / 2, y: r.top + r.height / 2 }, 750, 1);
      }
    }
  }
  function compileD2(src) {
    return fetch("/voice/d2", { method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" }, body: src })
      .then(function (res) { if (!res.ok) throw new Error("d2 " + res.status); return res.text(); });
  }

  // ────────────────────────── caption + transcript ──────────────────────────
  var caption = null, drawer = null, drawerLog = null;
  function capStatus(text) { caption.className = "on dim"; caption.id = "vs-caption"; caption.textContent = text; caption.classList.add("on"); caption.className = "dim on"; captionShow("dim", text); }
  function captionShow(kind, html) {
    caption.className = kind ? kind + " on" : "on";
    if (kind === "you" || kind === "dim") caption.textContent = html;
    else caption.innerHTML = html;
  }
  function captionHide() { caption.className = ""; }
  function logLine(who, text) {
    transcript.push({ who: who, text: text });
    if (!drawerLog) return;
    var d = document.createElement("div");
    d.className = "ln " + who;
    d.innerHTML = "<b>" + (who === "you" ? "you" : "autopoet") + "</b>";
    d.appendChild(document.createTextNode(text));
    drawerLog.appendChild(d);
    drawerLog.scrollTop = drawerLog.scrollHeight;
  }

  // ────────────────────────── listener: react to YOUR words ──────────────────────────
  var LEX = {
    joy: "happy joy love great wonderful amazing win won awesome excited glad proud beautiful perfect nice cool thanks thank",
    sad: "sad lost lonely hurt broke broken fail failed sorry tired hard stuck confused",
    anger: "angry mad annoyed unfair hate stupid wrong bug crash error frustrated",
    fear: "worried scared afraid nervous anxious risk dangerous unsure",
    surprise: "wow whoa really surprised unexpected huh what"
  };
  var W2E = {};
  Object.keys(LEX).forEach(function (e) { LEX[e].split(" ").forEach(function (w) { W2E[w] = e; }); });
  var LISTEN_FACE = {
    joy: ["smirk", "raised"], sad: ["neutral", "worried"], anger: ["neutral", "worried"],
    fear: ["neutral", "worried"], surprise: ["surprised", "raised"], none: ["neutral", "raised"]
  };
  function reactToUser(text) {
    var sc = { joy: 0, sad: 0, anger: 0, fear: 0, surprise: 0 };
    (text.toLowerCase().match(/[a-z]+/g) || []).forEach(function (w) { if (W2E[w]) sc[W2E[w]]++; });
    var dom = null, n = 0;
    Object.keys(sc).forEach(function (e) { if (sc[e] > n) { n = sc[e]; dom = e; } });
    var f = LISTEN_FACE[dom || "none"];
    mood = f[0]; setMouth(f[0]); setBrows(f[1]);
    if (dom === "surprise") gesture("--nod", [-6, 2, -4, 0], 130);
    else nod();
  }

  // ────────────────────────── stage movement ──────────────────────────
  var stagePos = { x: 0, y: 0 };
  function moveTo(xPx, yPx) {
    var dx = xPx - stagePos.x, dy = yPx - stagePos.y, dist = Math.hypot(dx, dy);
    if (dist < 4) return 0;
    var ms = Math.max(420, Math.min(1300, dist * 1.15));
    if (dist > 40) hideHands();
    scene.style.transition = "transform " + ms + "ms cubic-bezier(.3, .9, .35, 1)";
    stagePos = { x: xPx, y: yPx };
    scene.style.setProperty("--sx", xPx + "px");
    scene.style.setProperty("--sy", yPx + "px");
    var lean = Math.max(-7, Math.min(7, dx * 0.02));
    cube.style.setProperty("--rz", lean + "deg");
    gesture("--nod", [2.5, -1, 2, 0], Math.max(120, ms / 4));
    clearTimeout(moveTo._t);
    moveTo._t = later(setTimeout(function () { cube.style.setProperty("--rz", "0deg"); }, ms));
    return ms;
  }
  function stageCenter() {
    var R = stageEl.getBoundingClientRect();
    return { x: R.left + R.width / 2 + stagePos.x, y: R.top + R.height / 2 + stagePos.y };
  }

  // ────────────────────────── Kokoro worker (persists across calls) ──────────────────────────
  var kokoro = false, kWorker = null, kSeq = 0, kPending = {};
  var VOICE_ID = "af_heart";
  function bootKokoro() {
    if (kWorker) return;
    try {
      kWorker = new Worker("/static/vendor/kokoro-worker.mjs", { type: "module" });
      kWorker.onmessage = function (e) {
        var m = e.data;
        if (m.type === "ready") { kokoro = true; if (mounted && !playing) capStatus("ready — just talk"); }
        else if (m.type === "error") { kokoro = false; if (mounted) capStatus("voice offline — captions only"); }
        else if (m.type === "audio") {
          var cb = kPending[m.id]; if (!cb) return; delete kPending[m.id];
          if (m.error || !m.audio) cb(null);
          else cb({ audio: m.audio, sampling_rate: m.sr });
        }
      };
      kWorker.onerror = function () { kokoro = false; };
      kWorker.postMessage({ type: "load" });
    } catch (e) { kokoro = false; }
  }
  function kokoroGen(text) {
    return new Promise(function (resolve) {
      if (!kokoro || !kWorker) { resolve(null); return; }
      var id = ++kSeq; kPending[id] = resolve;
      kWorker.postMessage({ type: "gen", id: id, text: text, voice: VOICE_ID });
      later(setTimeout(function () { if (kPending[id]) { delete kPending[id]; resolve(null); } }, 15000));
    });
  }
  function wavFromRaw(raw) {
    var f = raw.audio || raw, sr = raw.sampling_rate || 24000, len = f.length;
    var buf = new ArrayBuffer(44 + len * 2), v = new DataView(buf);
    var w = function (o, s) { for (var i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    w(0, "RIFF"); v.setUint32(4, 36 + len * 2, true); w(8, "WAVE"); w(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
    v.setUint32(24, sr, true); v.setUint32(28, sr * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
    w(36, "data"); v.setUint32(40, len * 2, true);
    var o = 44;
    for (var i = 0; i < len; i++) { var x = Math.max(-1, Math.min(1, f[i])); v.setInt16(o, x < 0 ? x * 0x8000 : x * 0x7FFF, true); o += 2; }
    return new Blob([buf], { type: "audio/wav" });
  }

  // ────────────────────────── the performer ──────────────────────────
  var MOODS = {
    happy: ["smirk", "none"], excited: ["grin", "raised"],
    serious: ["neutral", "skeptical"], worried: ["neutral", "worried"],
    neutral: ["neutral", "none"]
  };
  var audioClip = null, playing = null, timer = null;
  function tokenize(text) {
    var stream = [], re = /\[([^\]]+)\]|(\S+)/g, t;
    while ((t = re.exec(text))) {
      if (t[1] !== undefined) stream.push({ dir: t[1].trim() });
      else stream.push({ word: t[2] });
    }
    return stream;
  }
  function stopPerform() {
    playing = null;
    clearTimeout(timer);
    clearInterval(talkT);
    if (audioClip) { try { audioClip.pause(); } catch (e) {} audioClip = null; }
    captionHide();
    hideHands();
    if (mounted) moveTo(0, 0);
    mood = "neutral"; setMouth("neutral"); setBrows("none");
  }
  async function perform(script) {
    stopPerform();
    var runId = {};
    playing = runId;
    var narration = script, g = script.match(/@graph\s*([\s\S]*?)@end/);
    if (g) {
      narration = script.replace(g[0], " ");
      try { mountGraphSVG(await compileD2(g[1].trim())); }
      catch (e) { graphBg.classList.remove("on"); }
    } else graphBg.classList.remove("on");
    if (playing !== runId) return;

    var stream = tokenize(narration);
    var words = [];
    stream.forEach(function (s) { if (s.word) { s._wi = words.length; words.push(s.word); } });
    if (!words.length) { stopPerform(); return; }
    logLine("poet", words.join(" "));

    var sentOf = [], counts = [], sText = [], sN = 0, cur = "";
    words.forEach(function (w, i) {
      sentOf[i] = sN; counts[sN] = (counts[sN] || 0) + 1;
      cur += (cur ? " " : "") + w;
      if (/[.!?]$/.test(w)) { sText[sN] = cur; cur = ""; sN++; }
    });
    if (cur) sText[sN] = cur;

    // pipeline synthesis: all sentences fired at once, speak on first arrival
    var clips = [], clipP = [];
    if (kokoro) {
      for (var s = 0; s < sText.length; s++) {
        clipP[s] = kokoroGen(sText[s]).then(function (raw) {
          return raw ? new Audio(URL.createObjectURL(wavFromRaw(raw))) : null;
        });
        clipP[s].then((function (idx) { return function (a) { clips[idx] = a; }; })(s));
      }
      clips[0] = await clipP[0];
      if (playing !== runId) return;
    }

    captionShow("", "");
    moveTo(0, stageEl.clientHeight * 0.12);
    mood = "smirk"; setMouth("smirk");

    var groups = [], gi = -1, pendDirs = [];
    stream.forEach(function (it) {
      if (it.word) {
        if (sentOf[it._wi] !== gi) { gi = sentOf[it._wi]; groups[gi] = { items: [] }; }
        pendDirs.forEach(function (d) { groups[gi].items.push(d); }); pendDirs = [];
        groups[gi].items.push(it);
      } else (gi >= 0 && groups[gi] ? groups[gi].items : pendDirs).push(it);
    });
    if (pendDirs.length && groups[gi]) pendDirs.forEach(function (d) { groups[gi].items.push(d); });

    function fireDir(d) {
      if (d[0] === "+") reveal(d.slice(1));
      else if (d.indexOf("point ") === 0) { var gp = pieces.nodes[d.slice(6).trim()]; if (gp) pointAt(gp, 2200); }
      else if (d.indexOf("move to ") === 0) {
        var n = pieces.nodes[d.slice(8).trim()];
        if (n) {
          var r = n.getBoundingClientRect(), R = stageEl.getBoundingClientRect();
          var nx = Math.max(-0.42, Math.min(0.42, (r.left + r.width / 2 - (R.left + R.width / 2)) / R.width)) * R.width;
          moveTo(nx, R.height * 0.12);
        }
      }
      else if (d === "move center") moveTo(0, stageEl.clientHeight * 0.12);
      else if (d.indexOf("mood ") === 0) { var mo = MOODS[d.slice(5).trim()]; if (mo) { mood = mo[0]; setMouth(mo[0]); setBrows(mo[1]); } }
      else if (d === "wave") wave();
      else if (d === "wave2") wave(true);
      else if (d === "thumbsup") thumbsUp();
      else if (d === "shrug") { shrug(); setBrows("raised"); later(setTimeout(function () { setBrows("none"); }, 1300)); }
      else if (d === "nod") nod();
    }

    var sIdx = 0, lastPrewalk = null;
    (async function nextSentence() {
      if (playing !== runId) return;
      if (sIdx >= groups.length) { later(setTimeout(function () { if (playing === runId) { stopPerform(); if (kokoro) capStatus("ready — just talk"); } }, 700)); return; }
      var g2 = groups[sIdx], sentNo = sIdx; sIdx++;
      if (!g2) { nextSentence(); return; }

      var clip = clips[sentNo] !== undefined ? clips[sentNo] : await (clipP[sentNo] || Promise.resolve(null));
      if (playing !== runId) return;
      audioClip = clip;

      var durMs;
      if (clip) {
        if (!(isFinite(clip.duration) && clip.duration > 0)) {
          await new Promise(function (r) { clip.addEventListener("loadedmetadata", r, { once: true }); later(setTimeout(r, 1500)); });
        }
        durMs = (isFinite(clip.duration) && clip.duration > 0) ? clip.duration * 1000 : 0;
      }
      if (!durMs) { var wc = g2.items.filter(function (x) { return x.word; }).length; durMs = 260 * wc + 500; }
      if (playing !== runId) return;

      var totalW = 0;
      g2.items.forEach(function (x) { if (x.word) totalW += x.word.length + 1; });
      totalW = totalW || 1;
      var acc = 0, trailingPause = 0;
      g2.items.forEach(function (x) {
        x._t = (acc / totalW) * durMs;
        if (x.word) acc += x.word.length + 1;
        else if (x.dir && x.dir.indexOf("pause ") === 0) trailingPause = +x.dir.slice(6) || 0;
      });

      if (clip) { attachAnalyser(clip); clip.play().catch(function () {}); }

      g2.items.forEach(function (x) {
        later(setTimeout(function () {
          if (playing !== runId) return;
          if (x.dir) { fireDir(x.dir); return; }
          talkWord(x.word);
          var gw = x._wi, s0 = gw, s1 = gw;
          while (s0 > 0 && !/[.!?]$/.test(words[s0 - 1])) s0--;
          while (s1 < words.length - 1 && !/[.!?]$/.test(words[s1])) s1++;
          captionShow("", '<span class="said">' + words.slice(s0, gw).join(" ") +
            '</span> <span class="word-now">' + x.word + "</span> " + words.slice(gw + 1, s1 + 1).join(" "));
          var idx = g2.items.indexOf(x);
          for (var k = idx + 1; k < Math.min(g2.items.length, idx + 8); k++) {
            var dd = g2.items[k].dir; if (!dd) continue;
            if (dd.indexOf("point ") === 0) {
              var nn = pieces.nodes[dd.slice(6).trim()];
              if (nn && nn !== lastPrewalk) {
                lastPrewalk = nn;
                var rr = nn.getBoundingClientRect();
                walkTo({ x: rr.left + rr.width / 2, y: rr.top + rr.height / 2 });
              }
              break;
            }
            if (dd.indexOf("move") === 0) break;
          }
        }, x._t));
      });

      var advanced = false;
      var go = function () {
        if (advanced || playing !== runId) return;
        advanced = true;
        later(setTimeout(nextSentence, trailingPause + 120));
      };
      if (clip) { clip.addEventListener("ended", go, { once: true }); timer = later(setTimeout(go, durMs + 1200)); }
      else timer = later(setTimeout(go, durMs + trailingPause));
    })();
  }

  // ────────────────────────── the conversation loop ──────────────────────────
  var history = [];
  async function ask(userText) {
    userText = (userText || "").trim();
    if (!userText || !mounted) return;
    captionShow("you", userText);
    logLine("you", userText);
    reactToUser(userText);
    history.push({ role: "user", content: userText });
    var ctrl = new AbortController();
    var killer = later(setTimeout(function () { ctrl.abort(); }, 30000));
    try {
      var res = await fetch("/voice/brain", { method: "POST", signal: ctrl.signal,
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify({ history: history.slice(-16) }) });
      clearTimeout(killer);
      if (!res.ok) {
        var e = await res.json().catch(function () { return {}; });
        capStatus(e.error || ("brain error " + res.status));
        mood = "neutral"; setMouth("neutral"); setBrows("none");
        return;
      }
      var data = await res.json();
      history.push({ role: "assistant", content: data.reply });
      await perform(data.reply);
    } catch (err) {
      clearTimeout(killer);
      capStatus("brain unreachable");
      mood = "neutral"; setMouth("neutral"); setBrows("none");
    }
  }

  // ────────────────────────── mic + VAD ──────────────────────────
  var micVad = null, depsReady = null;
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src; s.onload = resolve; s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  function ensureDeps() {
    if (depsReady) return depsReady;
    depsReady = (async function () {
      if (!window.ort) await loadScript("/static/vendor/ort.wasm.min.js");
      if (window.ort) ort.env.wasm.wasmPaths = "/static/vendor/";
      if (!window.vad) await loadScript("/static/vendor/bundle.min.js");
    })();
    return depsReady;
  }
  async function startVAD() {
    try {
      await ensureDeps();
      if (!window.vad) { capStatus("voice detection unavailable — type in the transcript"); return; }
      micVad = await vad.MicVAD.new({
        baseAssetPath: "/static/vendor/", onnxWASMBasePath: "/static/vendor/",
        onSpeechStart: function () {
          if (!mounted) return;
          if (playing) stopPerform();                  // barge-in
          setBrows("raised");
          captionShow("you", "…");
        },
        onSpeechEnd: async function (audio) {
          if (!mounted) return;
          captionShow("dim", "transcribing…");
          var blob = wavFromRaw({ audio: audio, sampling_rate: 16000 });
          try {
            var r = await fetch("/voice/dictate", { method: "POST",
              headers: { authorization: "Bearer " + TOKEN, "content-type": "audio/wav" }, body: blob });
            var text = (await r.text()).trim();
            if (r.ok && text && !/^refused:/.test(text)) ask(text);
            else { captionHide(); capStatus("didn't catch that"); }
          } catch (e) { captionHide(); capStatus("transcription failed"); }
        }
      });
      micVad.start();
    } catch (e) {
      var name = (e && e.name) || "";
      if (name === "NotAllowedError" || name === "SecurityError") capStatus("mic permission denied — type in the transcript");
      else if (name === "NotFoundError") capStatus("no microphone found");
      else capStatus("voice engine failed" + (name ? " (" + name + ")" : ""));
    }
  }
  function stopVAD() {
    if (micVad) { try { micVad.pause(); } catch (e) {} try { micVad.destroy && micVad.destroy(); } catch (e) {} micVad = null; }
  }

  // ────────────────────────── mount / unmount ──────────────────────────
  function buildDOM() {
    root = document.createElement("div");
    root.id = "vs-root";
    root.innerHTML =
      (adopt ? '' : '<div class="vs-paper"></div>') +
      '<div id="vs-graph-bg" aria-hidden="true"></div>' +
      (adopt ? '' :
      '<div id="vs-stagebox">' +
      '  <div id="vs-scene">' +
      '    <div id="vs-cube">' +
      '      <div class="vs-layer vs-face-layer" id="vs-face" aria-hidden="true">' + FACE_SVG + '</div>' +
      '      <div class="vs-hand" id="vs-hand-r" aria-hidden="true"></div>' +
      '      <div class="vs-hand left" id="vs-hand-l" aria-hidden="true"></div>' +
      '    </div>' +
      '  </div>' +
      '</div>') +
      '<div id="vs-caption" role="status" aria-live="polite"></div>' +
      '<div id="vs-drawer" role="log" aria-label="Voice transcript">' +
      '  <div class="hd"><span>transcript</span><button id="vs-drawer-x" aria-label="close">×</button></div>' +
      '  <div id="vs-drawer-log"></div>' +
      '  <div class="ft"><input id="vs-drawer-in" placeholder="type to the autopoet…" spellcheck="false" aria-label="Message the autopoet"></div>' +
      '</div>';
    stageEl.appendChild(root);

    // fixed-position ants overlay lives at body level (viewport coordinates)
    overlay = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    overlay.id = "vs-ref-overlay";
    document.body.appendChild(overlay);

    graphBg = document.getElementById("vs-graph-bg");
    caption = document.getElementById("vs-caption");
    drawer = document.getElementById("vs-drawer");
    drawerLog = document.getElementById("vs-drawer-log");

    if (adopt) {
      // ADOPT the app's real self-node cube: same body, same primary face
      scene = adopt.scene;
      cube = adopt.cube;
      faceMount = cube.querySelector(".sc-face");
      facePrefix = adopt.prefix || "ap-";
      // the app's face has no brows group — give it one (first child of the
      // face root so brows render beneath the eye/mouth layers)
      var faceRoot = document.getElementById(facePrefix + "face");
      if (faceRoot && !document.getElementById(facePrefix + "brows")) {
        var bg = document.createElementNS("http://www.w3.org/2000/svg", "g");
        bg.id = facePrefix + "brows";
        faceRoot.insertBefore(bg, faceRoot.firstChild);
      }
      // hands join the adopted cube (they ride its 3D transform)
      var hr = document.createElement("div"); hr.className = "vs-hand"; hr.id = "vs-hand-r";
      var hl = document.createElement("div"); hl.className = "vs-hand left"; hl.id = "vs-hand-l";
      cube.appendChild(hr); cube.appendChild(hl);
      hands = { r: hr, l: hl };
    } else {
      cube = document.getElementById("vs-cube");
      scene = document.getElementById("vs-scene");
      faceMount = document.getElementById("vs-face");
      facePrefix = "vs-ap-";
      hands = { r: document.getElementById("vs-hand-r"), l: document.getElementById("vs-hand-l") };
      buildCube();
      setMouth("neutral");
    }

    // transcript drawer wiring (large-type accessibility view + typed input)
    listen(document.getElementById("vs-drawer-x"), "click", function () { drawer.classList.remove("on"); });
    var din = document.getElementById("vs-drawer-in");
    listen(din, "keydown", function (e) {
      if (e.key !== "Enter") return;
      var t = din.value.trim();
      if (!t) return;
      din.value = "";
      ask(t);
    });
    transcript.forEach(function (l) { logLine._replay = true; });
    // replay any prior transcript into the fresh drawer
    var prior = transcript.slice(); transcript = [];
    prior.forEach(function (l) { logLine(l.who, l.text); });

    // the call bar: swap the small text input for the transcript button
    if (callinEl) callinEl.style.display = "none";
    var tb = document.createElement("button");
    tb.id = "vs-tbtn";
    tb.setAttribute("aria-label", "Show full transcript");
    tb.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 6h16M4 12h10M4 18h13"/></svg><span>transcript</span>';
    listen(tb, "click", function () { drawer.classList.toggle("on"); });
    if (callinEl && callinEl.parentNode) callinEl.parentNode.insertBefore(tb, callinEl);
    buildDOM._tbtn = tb;
  }

  var appHooks = null;   // { selfSpot, hideWorld, showWorld, resync } from the real app
  var adopt = null;      // { scene, cube, prefix } — the app's own self-node cube
  function enter(opts) {
    if (mounted) return;
    opts = opts || {};
    TOKEN = opts.token || TOKEN;
    stageEl = opts.stage || document.getElementById("stage");
    callbarEl = opts.callbar || document.getElementById("callbar");
    callinEl = opts.callin || document.getElementById("callin");
    adopt = opts.adopt || null;
    appHooks = (opts.selfSpot && opts.hideWorld && opts.showWorld)
      ? { selfSpot: opts.selfSpot, hideWorld: opts.hideWorld, showWorld: opts.showWorld,
          resync: opts.resync || function () {} }
      : null;
    injectCSS();
    buildDOM();
    mounted = true;
    startBlink();
    startGaze();
    bootKokoro();

    if (adopt && appHooks) {
      // SEAMLESS RELEASE: the camera is settling on the head (the app's
      // zoomTo). When it lands, the world recedes and the SAME cube that
      // lives as the self node is released to float free — no copy, no swap.
      root.classList.add("on");
      var settle = opts.settleMs !== undefined ? opts.settleMs : 600;
      later(setTimeout(function () { appHooks.hideWorld(); }, Math.max(0, settle - 350)));
      later(setTimeout(function () {
        if (!mounted) return;
        var spot = appHooks.selfSpot();
        scene.dataset.free = "1";                       // the app stops node-tracking
        scene.classList.add("vs-free");
        scene.style.transform = "";                     // the class + vars own it now
        scene.style.transition = "none";
        scene.style.setProperty("--sx", spot.sx + "px");
        scene.style.setProperty("--sy", spot.sy + "px");
        scene.style.setProperty("--sc", spot.sc.toFixed(4));
        stagePos = { x: spot.sx, y: spot.sy };
        void scene.offsetWidth;                         // commit the start frame
        scene.style.transition = "";                    // .vs-free transition resumes
        moveTo(0, 0);                                   // glide to center stage…
        scene.style.setProperty("--sc", "1");           // …growing to full size
        capStatus(kokoro ? "ready — just talk" : "loading local voice…");
        startVAD();
        later(setTimeout(function () { if (mounted && !playing) wave(); }, 900));
      }, settle));
    } else {
      // standalone (the /voice/widget page): own paper, own cube, fade in
      stagePos = { x: 0, y: 0 };
      stageEl.classList.add("vs-whiteboard");
      requestAnimationFrame(function () { root.classList.add("on"); });
      capStatus(kokoro ? "ready — just talk" : "loading local voice…");
      startVAD();
      later(setTimeout(function () { if (mounted && !playing) wave(); }, 600));
    }
  }

  function exit() {
    if (!mounted) return;
    var hooks = appHooks, adopted = adopt, sceneRef = scene, rootRef = root, oRef = overlay;
    var handRefs = hands;
    mounted = false;
    stopPerform();
    stopVAD();
    if (buildDOM._tbtn && buildDOM._tbtn.parentNode) buildDOM._tbtn.parentNode.removeChild(buildDOM._tbtn);
    if (callinEl) callinEl.style.display = "";

    function cleanup(delay) {
      setTimeout(function () {
        if (rootRef && rootRef.parentNode) rootRef.parentNode.removeChild(rootRef);
        if (oRef && oRef.parentNode) oRef.parentNode.removeChild(oRef);
        if (adopted && handRefs) {
          [handRefs.r, handRefs.l].forEach(function (h) {
            if (h && h.parentNode) h.parentNode.removeChild(h);
          });
        }
      }, delay);
      clearAll();
      root = null; overlay = null; faceMount = null;
      graphBg = null; caption = null; drawer = null; drawerLog = null; hands = null;
      if (!adopted) { cube = null; scene = null; }
      appHooks = null; adopt = null;
      // kokoro worker + conversation history survive for the next call
    }

    if (adopted && hooks && sceneRef) {
      // glide home: back onto the self node's exact footprint, world returns
      if (rootRef) {
        var gb = rootRef.querySelector("#vs-graph-bg");
        if (gb) gb.classList.remove("on");
      }
      var spot = hooks.selfSpot();
      sceneRef.style.transition = "transform .65s cubic-bezier(.4,.9,.4,1)";
      sceneRef.style.setProperty("--sx", spot.sx + "px");
      sceneRef.style.setProperty("--sy", spot.sy + "px");
      sceneRef.style.setProperty("--sc", spot.sc.toFixed(4));
      setTimeout(function () { hooks.showWorld(); }, 480);
      setTimeout(function () {
        // hand the cube back to the graph's node-tracking
        sceneRef.classList.remove("vs-free");
        sceneRef.style.transition = "";
        sceneRef.style.removeProperty("--sx");
        sceneRef.style.removeProperty("--sy");
        sceneRef.style.removeProperty("--sc");
        sceneRef.dataset.free = "0";
        hooks.resync();
        setMouth("neutral"); setBrows("none");
        if (rootRef) rootRef.classList.remove("on");
      }, 680);
      cleanup(1150);
    } else {
      stageEl.classList.remove("vs-whiteboard");
      if (rootRef) rootRef.classList.remove("on");
      cleanup(500);
    }
  }

  window.VoiceStage = { enter: enter, exit: exit, ask: ask };
})();
