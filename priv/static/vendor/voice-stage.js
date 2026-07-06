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
  // exit()'s world-restore timers — cancelled if a new stage mounts before
  // they fire (the lab's instant restart), else the returning vault graph
  // lands ON TOP of the fresh plan session
  var exitTimers = [];
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
    ".vs-paper { position:absolute; inset:0; z-index:1; background:var(--paper,#fff);",
    "  background-image:linear-gradient(var(--grid,rgba(18,19,22,.07)) 1px, transparent 1px),",
    "  linear-gradient(90deg, var(--grid,rgba(18,19,22,.07)) 1px, transparent 1px);",
    "  background-size:24px 24px; }",
    // the session deck renders INTO the d2 board space (#vs-graph-bg):
    // reveal.js embedded, transparent, chrome hidden, toon ink
    "#vs-graph-bg .reveal { font-family:ui-monospace,Menlo,monospace; width:100%; height:100%; }",
    "#vs-graph-bg .reveal, #vs-graph-bg .reveal .slides section { background:transparent !important; }",
    "#vs-graph-bg .reveal .controls, #vs-graph-bg .reveal .progress, #vs-graph-bg .reveal .slide-number { display:none !important; }",
    "#vs-graph-bg .reveal .slides section { color:#121316; text-align:left; }",
    "#vs-graph-bg .reveal h1, #vs-graph-bg .reveal h2, #vs-graph-bg .reveal h3 { color:#121316; font-family:inherit;",
    "  text-transform:none; letter-spacing:0; margin-bottom:.5em; }",
    "#vs-graph-bg .reveal h1 { font-size:1.5em; } #vs-graph-bg .reveal h2 { font-size:1.15em; }",
    "#vs-graph-bg .reveal h1:after, #vs-graph-bg .reveal h2:after { content:''; display:block; width:64px; height:3px;",
    "  background:#121316; border-radius:2px; margin-top:10px; }",
    "#vs-graph-bg .reveal ul, #vs-graph-bg .reveal ol { display:block; margin-left:1em; font-size:.72em; line-height:1.55; }",
    "#vs-graph-bg .reveal li { margin:.3em 0; }",
    "#vs-graph-bg .reveal p { font-size:.72em; }",
    "#vs-graph-bg .reveal table { font-size:.6em; border-collapse:collapse; }",
    "#vs-graph-bg .reveal th, #vs-graph-bg .reveal td { border:1.6px solid #121316; padding:.35em .7em; }",
    "#vs-graph-bg .reveal pre { width:100%; box-shadow:none; background:#fff; border:1.6px solid #121316; border-radius:12px; font-size:.5em; }",
    "#vs-graph-bg .reveal code { color:#121316; }",
    "#vs-graph-bg .reveal .mm-slide { display:flex; justify-content:center; }",
    "#vs-graph-bg .reveal .mm-slide svg { max-width:100%; height:auto; }",
    "#vs-graph-bg { position:absolute; left:50%; top:40%; transform:translate(-50%,-50%); z-index:3;",
    "  width:min(86%,1080px); pointer-events:none; opacity:0; transition:opacity .5s ease-out; }",
    "#vs-graph-bg.on { opacity:1; }",
    "#vs-graph-bg svg { width:100%; height:auto; display:block; }",
    "#vs-graph-bg .shape rect, #vs-graph-bg .shape path { fill:#fff; stroke:#121316; stroke-width:1.3; }",
    "#vs-graph-bg text { fill:#121316 !important; font-family:ui-monospace,Menlo,monospace !important; font-size:15px !important; }",
    "#vs-graph-bg path.connection { stroke:#121316 !important; stroke-width:1.7 !important; }",
    "#vs-graph-bg marker path, #vs-graph-bg marker polygon { fill:#121316 !important; stroke:none !important; }",
    "#vs-graph-bg .m-hidden { opacity:0 !important; }",
    "#vs-graph-bg .m-pop { animation:vs-mpop .45s cubic-bezier(.34,1.5,.4,1) both; transform-box:fill-box; transform-origin:center; }",
    "@keyframes vs-mpop { from { opacity:0; transform:scale(.55);} to { opacity:1; transform:scale(1);} }",
    "#vs-graph-bg .m-fade { animation:vs-mfade .5s ease-out both; }",
    // ── the lightweight deck: ONE slide visible at a time, a white card on the
    //    grid. .cur is shown; the rest are display:none (guaranteed pagination).
    "#vs-graph-bg .vsd-wrap { position:relative; width:100%; height:100%; background:#fff;",
    "  border:1.7px solid #121316; border-radius:18px; box-shadow:6px 8px 0 rgba(18,19,22,.10); overflow:hidden; }",
    "#vs-graph-bg .vsd-slide { position:absolute; inset:0; display:none; flex-direction:column;",
    "  justify-content:center; padding:44px 54px; box-sizing:border-box; text-align:left; }",
    "#vs-graph-bg .vsd-slide.cur { display:flex; animation:vs-mfade .4s ease-out both; }",
    "#vs-graph-bg .vsd-slide h1 { font:800 34px/1.15 ui-sans-serif,system-ui; color:#16161a; margin:0 0 14px; }",
    "#vs-graph-bg .vsd-slide h2 { font:800 26px/1.2 ui-sans-serif,system-ui; color:#16161a; margin:0 0 12px; }",
    "#vs-graph-bg .vsd-slide h3 { font:700 20px/1.2 ui-sans-serif,system-ui; color:#2a2f37; margin:0 0 10px; }",
    "#vs-graph-bg .vsd-slide p { font:400 19px/1.5 ui-sans-serif,system-ui; color:#2a2f37; margin:6px 0; }",
    "#vs-graph-bg .vsd-slide ul { margin:8px 0 0; padding-left:24px; }",
    "#vs-graph-bg .vsd-slide li { font:400 19px/1.55 ui-sans-serif,system-ui; color:#2a2f37; margin:7px 0; }",
    "#vs-graph-bg .vsd-slide blockquote { margin:8px 0; padding-left:14px; border-left:3px solid #c9cdd2;",
    "  font:italic 18px/1.5 ui-sans-serif,system-ui; color:#5a6068; }",
    "#vs-graph-bg .vsd-slide b { color:#16161a; } #vs-graph-bg .vsd-slide code { font:15px ui-monospace,monospace;",
    "  background:#eef0f2; padding:1px 5px; border-radius:5px; }",
    "#vs-graph-bg .vsd-slide .vsd-mermaid { display:flex; justify-content:center; margin:10px 0; }",
    "#vs-graph-bg .vsd-slide .vsd-mermaid svg { max-width:100%; max-height:360px; height:auto; }",
    "#vs-graph-bg .vsd-slide .vsd-fence { font:13px ui-monospace,monospace; white-space:pre-wrap; color:#5a6068; }",
    "@keyframes vs-mfade { from { opacity:0; } to { opacity:1; } }",
    "#vs-stagebox { position:absolute; inset:0; display:grid; place-items:center; pointer-events:none; }",
    // outline follows the SAME theme var the graph nodes use (--face-outline:
    // black in light, white in dark) — was hardcoded #121316 (wrong in dark)
    "#vs-scene { width:132px; height:132px; pointer-events:auto; --toon:1.6px; --ol:var(--face-outline,#121316);",
    "  filter:drop-shadow(var(--toon) 0 0.3px var(--ol)) drop-shadow(calc(-1*var(--toon)) 0 0.3px var(--ol))",
    "  drop-shadow(0 var(--toon) 0.3px var(--ol)) drop-shadow(0 calc(-1*var(--toon)) 0.3px var(--ol))",
    "  drop-shadow(0 16px 26px rgba(18,19,22,.04));",
    "  transform:translate(var(--sx,0px), var(--sy,0px)) scale(var(--sc,1));",
    "  transition:transform .8s cubic-bezier(.3,1,.35,1); }",
    "#vs-cube { width:100%; height:100%; position:relative; transform-style:preserve-3d;",
    "  transform:rotateX(calc(var(--rx,0deg) + var(--nod,0deg) + var(--br,0deg))) rotateY(var(--ry,0deg)) rotateZ(var(--rz,0deg));",
    "  transition:transform .12s ease-out; cursor:pointer; }",
    // shape honors data-ap-shape (squircle default), body follows --face-bg —
    // a new user gets a squircle white cube with a theme-aware outline
    "#vs-cube .vs-layer { position:absolute; inset:0; border-radius:32px; }",
    ":root[data-ap-shape=\"round\"] #vs-cube .vs-layer { border-radius:50%; }",
    ":root[data-ap-shape=\"blocky\"] #vs-cube .vs-layer { border-radius:9px; }",
    "#vs-cube .vs-face-layer { background:var(--face-bg,#fff); display:grid; place-items:center; }",
    ".vs-face-layer svg { display:block; width:100%; height:100%; }",
    ".vs-hand { position:absolute; left:0; top:0; width:30px; height:40px; pointer-events:none;",
    "  opacity:var(--po,0); transform-origin:15px 20px;",
    "  transform:translate(var(--hx,51px), var(--hy,120px)) translateZ(67px) rotate(var(--hr,0deg)) scale(var(--hs,0));",
    "  transition:transform .3s cubic-bezier(.34,1.45,.4,1), opacity .18s ease-out; }",
    ".vs-hand svg { width:100%; height:100%; display:block; }",
    ".vs-hand.left svg { transform:scaleX(-1); }",
    "#vs-ref-overlay { position:fixed; inset:0; pointer-events:none; z-index:8; }",
    // the thought CLOUD: fills the air between 'heard you' and 'speaking'
    "#vs-think { position:absolute; top:-74px; right:-64px; width:104px; height:78px; pointer-events:none;",
    "  opacity:0; transform:translateY(6px) scale(.85); transition:opacity .25s ease, transform .25s cubic-bezier(.3,1.4,.5,1); }",
    "#vs-think.on { opacity:1; transform:translateY(0) scale(1); }",
    "#vs-think svg { display:block; width:100%; height:100%; overflow:visible; }",
    "#vs-think .dot { animation:vs-think-b 1.2s infinite ease-in-out; transform-origin:center; transform-box:fill-box; }",
    "#vs-think .dot:nth-child(2) { animation-delay:.15s; }",
    "#vs-think .dot:nth-child(3) { animation-delay:.3s; }",
    "@keyframes vs-think-b { 0%,60%,100% { transform:translateY(0); opacity:.45; }",
    "  30% { transform:translateY(-3px); opacity:1; } }",
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
    "#stage.vs-whiteboard #callcaption { display:none; }",
    // ── BEAM-IN: while warming, the cube is FACELESS (works for the WebGL
    //    #self-cube's .sc-face and the DOM fallback's .vs-face-layer) and a
    //    loading bar sits beneath it. The spin + land motion are driven in JS
    //    (via --ry/--sc, which the WebGL avatar reads) so ONE cube serves all.
    ".vs-faceless .sc-face, .vs-faceless .vs-face-layer { opacity:0; transition:opacity .25s ease; }",
    ".sc-face, .vs-face-layer { transition:opacity .35s ease; }",
    "#vs-loadbar { position:absolute; left:50%; top:calc(50% + 92px); transform:translateX(-50%); width:104px;",
    "  height:4px; border-radius:3px; background:rgba(18,19,22,.12); overflow:hidden; z-index:7; opacity:0;",
    "  transition:opacity .3s ease; }",
    "#vs-loadbar.on { opacity:1; }",
    "#vs-loadbar i { display:block; height:100%; width:38%; border-radius:3px; background:var(--face-outline,#121316);",
    "  animation:vs-loadslide 1.15s ease-in-out infinite; }",
    "@keyframes vs-loadslide { 0% { transform:translateX(-120%);} 100% { transform:translateX(360%);} }"
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
    grim: '<path d="M34 49.5 Q40 46 46 49.5" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
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
    skeptical: '<path d="M28 29.5 Q31 27.3 34 29.5 M46.5 31.5 h5" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>',
    angry: '<path d="M28.5 28.8 L33.5 31.4 M46.5 31.4 L51.5 28.8" stroke="#121316" stroke-width="2" stroke-linecap="round" fill="none"/>'
  };
  // Hand poses render with a STAMP-UNION outline: the pose's shapes are
  // defined once (no strokes), stamped 8 times in ink at 1.6px offsets, then
  // painted once in white on top. That yields ONE merged toon silhouette —
  // a clean mitten line instead of per-finger strokes — in pure SVG, which
  // every engine (including WKWebView, where filter unions fail on 3D
  // subtrees) renders identically.
  var _poseSeq = 0;
  function poseSVG(shapes) {
    var id = "hp" + (++_poseSeq);
    var stamps = "";
    var R = 1.6, D8 = R * 0.7071;
    [[R, 0], [-R, 0], [0, R], [0, -R], [D8, D8], [D8, -D8], [-D8, D8], [-D8, -D8]]
      .forEach(function (o) {
        stamps += '<use href="#' + id + '" x="' + o[0].toFixed(2) + '" y="' + o[1].toFixed(2) + '" fill="#121316"/>';
      });
    return '<svg viewBox="-4 -4 38 48"><defs><g id="' + id + '">' + shapes + '</g></defs>' +
           stamps + '<use href="#' + id + '" fill="#fff"/></svg>';
  }
  var POSE_SHAPES = {
    point: '<path d="M15 2.5 C19.4 2.5 22.5 6 22.5 11 L22.5 24 C22.5 32 19.4 37.5 15 37.5 C10.6 37.5 7.5 32 7.5 24 L7.5 11 C7.5 6 10.6 2.5 15 2.5 Z"/><ellipse cx="24" cy="26" rx="4.4" ry="6"/>',
    open: '<rect x="6.5" y="15" width="19" height="19" rx="8.5"/><rect x="7" y="3.5" width="5.4" height="15" rx="2.7"/><rect x="13.2" y="1.5" width="5.4" height="17" rx="2.7"/><rect x="19.4" y="3.5" width="5.4" height="15" rx="2.7"/><ellipse cx="27.2" cy="24.5" rx="3.6" ry="5.2"/>',
    thumb: '<rect x="6" y="16" width="17.5" height="16.5" rx="7.5"/><rect x="5.8" y="3" width="6.4" height="16" rx="3.2" transform="rotate(-9 9 11)"/>'
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

  // ── audio engine ──────────────────────────────────────────────────────
  // ONE AudioContext, created and resumed inside the user's voice-button
  // gesture (webviews block contexts/media started outside a gesture — this
  // was the "it writes but never speaks" bug). Clips are raw Float32 from
  // Kokoro played as AudioBufferSources: no <audio> elements, no autoplay
  // policy, exact durations for caption/viseme sync.
  var actx = null, analyser = null;
  function ensureAudio() {
    if (!actx) {
      actx = new (window.AudioContext || window.webkitAudioContext)();
      analyser = actx.createAnalyser();
      analyser.fftSize = 512;
      analyser.connect(actx.destination);
    }
    if (actx.state === "suspended") actx.resume();
  }
  function makeClip(raw) {   // {audio: Float32Array, sampling_rate} → playable clip
    ensureAudio();
    var f = raw.audio, sr = raw.sampling_rate || 24000;
    var buf = actx.createBuffer(1, f.length, sr);
    buf.getChannelData(0).set(f);
    return { buffer: buf, duration: buf.duration };
  }
  var clipNow = null;   // { src, t0 } while a sentence is sounding
  var streamSrcs = [];  // all scheduled sources of the current stream (to stop on cut)
  function playClip(clip, onended) {
    ensureAudio();
    stopClip();
    audioDriven = false;
    var src = actx.createBufferSource();
    src.buffer = clip.buffer;
    src.connect(analyser);
    clipNow = { src: src, t0: actx.currentTime };
    src.onended = function () { if (clipNow && clipNow.src === src) clipNow = null; if (onended) onended(); };
    src.start();
    startMouthLoop();
  }
  function stopClip() {
    if (clipNow) { try { clipNow.src.onended = null; clipNow.src.stop(); } catch (e) {} clipNow = null; }
    if (streamSrcs.length) {
      streamSrcs.forEach(function (s) { try { s.onended = null; s.stop(); } catch (e) {} });
      streamSrcs = [];
    }
  }

  // audio-driven mouth: amplitude gates the jaw, word vowels pick the family
  var audioDriven = false, curFamily = "wide", mouthRaf = null, env = 0;
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
  var liveEnergy = 0;   // 0..1, updated by the mouth loop while audio plays
  function startMouthLoop() {
    audioDriven = true;
    if (mouthRaf) return;
    var data = new Uint8Array(analyser.fftSize), lastShape = "";
    (function frame() {
      mouthRaf = requestAnimationFrame(frame);
      if (!mounted || !playing) { cancelAnimationFrame(mouthRaf); mouthRaf = null; return; }
      if (!clipNow) return;
      analyser.getByteTimeDomainData(data);
      var __s = 0;
      for (var __i = 0; __i < data.length; __i++) { var __d = (data[__i] - 128) / 128; __s += __d * __d; }
      liveEnergy = clipNow ? Math.min(1, Math.sqrt(__s / data.length) * 4) : 0;
      var s = 0;
      for (var i = 0; i < data.length; i++) { var v = (data[i] - 128) / 128; s += v * v; }
      var rms = Math.sqrt(s / data.length);
      env = Math.max(rms, env * 0.82);
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
  function setPose(h, pose) {
    if (h.dataset.pose === pose) return;
    h.dataset.pose = pose;
    // adopted cube renders hands in WebGL (avatar3d) — the div is then just an
    // invisible controller (position/rotation vars + pose), not the artwork
    if (adopt && window.Avatar3D) { h.innerHTML = ""; return; }
    h.innerHTML = poseSVG(POSE_SHAPES[pose]);   // standalone: stamped-union SVG art
  }
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
    if (!elTarget || !elTarget.isConnected) return;      // detached = nothing to point at
    var r = elTarget.getBoundingClientRect();
    if (r.width < 2 && r.height < 2) return;             // invisible/unlaid-out target
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
    graphBg.style.width = ""; graphBg.style.height = "";
    graphBg.innerHTML = svgText;
    showBoard("d2");
    var svg = graphBg.querySelector("svg");
    if (svg) {
      svg.removeAttribute("width"); svg.removeAttribute("height");
      // fit the stage: scale by aspect so wide flows fill sideways and tall
      // forms (sequence diagrams, stacked grids) never run out of frame
      var vb = (svg.getAttribute("viewBox") || "").split(/\s+/).map(Number);
      var ar = vb.length === 4 && vb[3] > 0 ? vb[2] / vb[3] : 1.6;
      var natural = vb.length === 4 ? vb[2] : 700;   // d2 units ≈ px at 1:1
      var maxW = (stageEl ? stageEl.clientWidth : innerWidth) * 0.62;
      var maxH = (stageEl ? stageEl.clientHeight : innerHeight) * 0.46;
      var w = Math.min(natural, 820, maxW, maxH * ar);   // shrink to fit, never blow up
      svg.style.width = w + "px";
      svg.style.height = (w / ar) + "px";
      svg.style.display = "block";
      svg.style.margin = "0 auto";
    }
    graphBg.querySelectorAll("rect").forEach(function (r) {
      if (r.closest("mask, defs, marker, pattern")) return;   // mask/def internals are NOT canvas
      var cls = r.getAttribute("class") || "";
      var fill = (r.getAttribute("fill") || "").toUpperCase();
      if (/fill-N7\b/.test(cls) || fill === "#FFFFFF" || fill === "#FFF" || fill === "WHITE") r.remove();
    });
    // edges + arrowheads: force INK via inline style (beats d2's embedded CSS
    // classes, which otherwise leave grey lines with mismatched blue heads)
    graphBg.querySelectorAll(".connection").forEach(function (c) {
      c.style.stroke = "#121316";
      c.style.strokeWidth = "1.7px";
    });
    graphBg.querySelectorAll("marker polygon, marker path, marker circle").forEach(function (m) {
      m.style.fill = "#121316";
      m.style.stroke = "none";
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
    // container children decode as dotted paths ("timeline.w1") but the model
    // cues bare ids — alias the last segment when it's unambiguous
    Object.keys(pieces.nodes).forEach(function (k) {
      var last = k.split(".").pop();
      if (last !== k && !(last in pieces.nodes)) pieces.nodes[last] = pieces.nodes[k];
    });
  }
  function revealNode(name, glance) {
    var n = pieces.nodes[name];
    if (!n || !n.classList.contains("m-hidden")) return;
    n.classList.remove("m-hidden"); n.classList.add("m-pop");
    // revealing a container shows what lives inside it
    n.querySelectorAll(".m-hidden").forEach(function (c) {
      c.classList.remove("m-hidden"); c.classList.add("m-pop");
    });
    if (glance) {
      var r = n.getBoundingClientRect();
      setAttention({ x: r.left + r.width / 2, y: r.top + r.height / 2 }, 750, 1);
    }
  }
  function reveal(spec) {
    spec = spec.replace(/\s+/g, "");
    if (spec.indexOf("->") > -1) {
      // an edge implies BOTH endpoints — the model often forgets the node cues
      var ends = spec.split("->");
      revealNode(ends[0], false);
      revealNode(ends[1], true);
      var g = pieces.edges[spec];
      if (g) { g.classList.remove("m-hidden"); g.classList.add("m-fade"); }
    } else {
      revealNode(spec, true);
    }
  }
  // nothing stays invisible once the performance is over
  function revealAll() {
    Object.keys(pieces.nodes).forEach(function (k) { revealNode(k, false); });
    Object.keys(pieces.edges).forEach(function (k) {
      var g = pieces.edges[k];
      if (g && g.classList.contains("m-hidden")) { g.classList.remove("m-hidden"); g.classList.add("m-fade"); }
    });
  }
  // ── mermaid: the rich diagram family (gantt, sequence, pie, state) ──
  var mmReady = null, mmSeq = 0;
  function ensureMermaid() {
    if (mmReady) return mmReady;
    mmReady = loadScript("/static/vendor/mermaid.min.js").then(function () {
      mermaid.initialize({
        startOnLoad: false, securityLevel: "loose", theme: "base",
        themeVariables: {
          background: "transparent",
          primaryColor: "#efe9fb", primaryBorderColor: "#121316", primaryTextColor: "#121316",
          secondaryColor: "#fff3d6", tertiaryColor: "#ffffff",
          lineColor: "#121316", textColor: "#121316",
          fontFamily: "ui-monospace, Menlo, monospace", fontSize: "16px",
          // gantt: purple task bars with ink borders on the paper
          taskBkgColor: "#cfc3ec", taskBorderColor: "#121316", taskTextColor: "#121316",
          taskTextOutsideColor: "#121316", taskTextLightColor: "#121316",
          activeTaskBkgColor: "#efe9fb", activeTaskBorderColor: "#121316",
          doneTaskBkgColor: "#e9e6df", doneTaskBorderColor: "#121316",
          critBkgColor: "#f6c6c0", critBorderColor: "#121316",
          sectionBkgColor: "rgba(142,124,195,.10)", altSectionBkgColor: "transparent",
          sectionBkgColor2: "rgba(142,124,195,.10)",
          gridColor: "rgba(18,19,22,.28)", todayLineColor: "#c0392b",
          // pie
          pie1: "#cfc3ec", pie2: "#ffe1a8", pie3: "#bfe3d0", pie4: "#f6c6c0",
          pieOuterStrokeColor: "#121316", pieSectionTextColor: "#121316",
          // sequence
          actorBkg: "#ffffff", actorBorder: "#121316", actorTextColor: "#121316",
          signalColor: "#121316", signalTextColor: "#121316",
          labelBoxBkgColor: "#efe9fb", labelBoxBorderColor: "#121316"
        },
        gantt: { fontSize: 15, sectionFontSize: 15, barHeight: 28, barGap: 7,
                 topPadding: 46, leftPadding: 96, gridLineStartPadding: 26 }
      });
    });
    return mmReady;
  }
  async function mountMermaid(mmSrc) {
    await ensureMermaid();
    var out = await mermaid.render("vsmm" + (++mmSeq), mmSrc);
    graphBg.style.width = ""; graphBg.style.height = "";
    graphBg.innerHTML = out.svg;
    showBoard("d2");
    var svg = graphBg.querySelector("svg");
    if (svg) {
      svg.style.background = "transparent";
      svg.removeAttribute("width"); svg.removeAttribute("height");
      var vb = (svg.getAttribute("viewBox") || "").split(/\s+/).map(Number);
      var ar = vb.length === 4 && vb[3] > 0 ? vb[2] / vb[3] : 1.6;
      var natural = vb.length === 4 ? vb[2] : 700;
      var maxW = (stageEl ? stageEl.clientWidth : innerWidth) * 0.62;
      var maxH = (stageEl ? stageEl.clientHeight : innerHeight) * 0.46;
      var w = Math.min(natural, 820, maxW, maxH * ar);
      svg.style.width = w + "px";
      svg.style.height = (w / ar) + "px";
      svg.style.display = "block";
      svg.style.margin = "0 auto";
    }
    // no white slabs on the paper
    graphBg.querySelectorAll("rect").forEach(function (r) {
      if (r.closest("mask, defs, marker, pattern")) return;
      var fill = (r.getAttribute("fill") || "").toUpperCase();
      if (r.classList.contains("background") || fill === "#FFFFFF" || fill === "WHITE") r.remove();
    });
    // best-effort pieces so [point x] still lands: flowchart nodes + gantt bars
    pieces = { nodes: {}, edges: {} };
    graphBg.querySelectorAll("g.node[id]").forEach(function (n) {
      var m = n.id.match(/^flowchart-(.+?)-\d+$/);
      if (m) pieces.nodes[m[1]] = n;
    });
    graphBg.querySelectorAll("rect.task[id], .task[id]").forEach(function (n) {
      pieces.nodes[n.id] = n;
    });
    // mermaid shows WHOLE — reveals are no-ops here (nothing is m-hidden)
  }

  // ── the session deck: a LIGHTWEIGHT markdown slide renderer (reveal.js is
  //    retired — it re-inited the whole deck + re-ran every mermaid on EVERY
  //    add, an O(n²) freeze, and failed to paginate in the webview → plain
  //    text). This appends ONLY the new slide, renders its mermaid ONCE, shows
  //    one slide at a time via a .cur class. Fully in our control. ──
  var deckMd = "", deckSlides = [], deckCur = 0, deckWrap = null, boardMode = null;
  function showBoard(which) {
    boardMode = which;
    if (graphBg) graphBg.classList.toggle("on", which != null);
  }
  function dEsc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  function dSpan(s) {
    return dEsc(s)
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/\*([^*]+)\*/g, "<i>$1</i>")
      .replace(/`([^`]+)`/g, "<code>$1</code>");
  }
  function dInline(text) {
    var lines = text.split("\n"), out = [], inList = false;
    var closeList = function () { if (inList) { out.push("</ul>"); inList = false; } };
    lines.forEach(function (ln) {
      var t = ln.trim();
      if (!t) { closeList(); return; }
      var h = t.match(/^(#{1,4})\s+(.*)/);
      if (h) { closeList(); var lv = h[1].length; out.push("<h" + lv + ">" + dSpan(h[2]) + "</h" + lv + ">"); return; }
      var b = t.match(/^[-*]\s+(.*)/);
      if (b) { if (!inList) { out.push("<ul>"); inList = true; } out.push("<li>" + dSpan(b[1]) + "</li>"); return; }
      var q = t.match(/^>\s+(.*)/);
      if (q) { closeList(); out.push("<blockquote>" + dSpan(q[1]) + "</blockquote>"); return; }
      closeList();
      out.push("<p>" + dSpan(t) + "</p>");
    });
    closeList();
    return out.join("");
  }
  function slideHtml(md) {
    // pull ```mermaid fences out; everything else is inline markdown
    var parts = String(md || "").split(/```mermaid\s*\n([\s\S]*?)```/);
    var html = "";
    for (var i = 0; i < parts.length; i++) {
      if (i % 2 === 1) html += '<div class="vsd-mermaid" data-src="' + encodeURIComponent(parts[i]) + '"></div>';
      else html += dInline(parts[i]);
    }
    return html;
  }
  function ensureDeckWrap() {
    if (deckWrap && deckWrap.parentNode && graphBg && graphBg.contains(deckWrap)) return deckWrap;
    if (!graphBg) return null;
    graphBg.style.width = "940px";
    graphBg.style.height = "570px";
    graphBg.innerHTML = '<div class="vsd-wrap"></div>';
    deckWrap = graphBg.querySelector(".vsd-wrap");
    deckSlides = []; deckCur = 0;
    return deckWrap;
  }
  async function renderMermaidIn(el) {
    var holders = el.querySelectorAll(".vsd-mermaid");
    for (var i = 0; i < holders.length; i++) {
      var src = decodeURIComponent(holders[i].getAttribute("data-src") || "");
      try {
        await ensureMermaid();
        var out = await mermaid.render("vsd" + (++mmSeq), src.trim());
        holders[i].innerHTML = out.svg;
      } catch (e) { holders[i].innerHTML = "<pre class='vsd-fence'>" + dEsc(src) + "</pre>"; }
    }
  }
  async function deckAppend(md) {
    if (!ensureDeckWrap()) return;
    var s = document.createElement("div");
    s.className = "vsd-slide";
    s.innerHTML = slideHtml(md);
    deckWrap.appendChild(s);
    deckSlides.push(s);
    showBoard("deck");
    deckShow(deckSlides.length - 1);   // reveal the new slide immediately (text)
    await renderMermaidIn(s);          // its diagram fills in a beat later
  }
  function deckShow(n) {
    if (!deckSlides.length) return;
    deckCur = Math.max(0, Math.min(deckSlides.length - 1, n));
    deckSlides.forEach(function (sl, i) { sl.classList.toggle("cur", i === deckCur); });
  }
  function deckGoto(n) { deckShow((n || 1) - 1); }
  function deckResetLocal() {
    deckMd = ""; deckSlides = []; deckCur = 0;
    if (deckWrap) { deckWrap.innerHTML = ""; }
    showBoard(null);
  }
  async function deckAdd(slideMd) {
    var r = await fetch("/voice/deck/add", { method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" }, body: slideMd });
    if (!r.ok) throw new Error("deck " + r.status);
    deckMd = await r.text();
    await deckAppend(slideMd);   // ONLY the new slide — no full re-render
  }

  var d2Cache = new Map();
  function compileD2(src) {
    if (d2Cache.has(src)) return d2Cache.get(src);
    var p = fetch("/voice/d2", { method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" }, body: src })
      .then(function (res) { if (!res.ok) throw new Error("d2 " + res.status); return res.text(); });
    d2Cache.set(src, p);
    return p;
  }

  // ────────────────────────── caption + transcript ──────────────────────────
  var caption = null, drawer = null, drawerLog = null;
  function capStatus(text) { captionShow("dim", text); }
  function captionShow(kind, html) {
    if (!mounted || !caption) return;   // late async callbacks after exit are no-ops
    caption.className = kind ? kind + " on" : "on";
    if (kind === "you" || kind === "dim") caption.textContent = html;
    else caption.innerHTML = html;
  }
  function captionHide() { if (caption) caption.className = ""; }
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

  // ────────────────────────── the DEEP listener ──────────────────────────
  // The demo's full engine, wired to the LIVE moonshine stream: lexicon with
  // negation + boosters, punctuation/caps energy, WHO-feels-it attribution
  // (you vs someone else vs aimed-at-you), humor and question routing, and
  // OCC-style arcs (hope→satisfaction/disappointment, fear→relief/confirmed)
  // tracked across the conversation. Partials get face/brows/tilt instantly
  // (one big gesture max per utterance); the final pass adds full gestures
  // and advances the arc state.
  var LEX = {
    joy: "happy joy love loved loves great wonderful amazing win won winning laugh smile delight delighted awesome fun celebrate celebration sunshine friend friends beautiful sweet excited exciting glad proud peace calm cozy warm yay best perfect brilliant hooray relief relieved promoted promotion raise married engaged safe healed passed thanks thank grateful cool nice fantastic incredible superb lovely enjoy enjoyed delicious tasty yummy favorite blessed lucky thrilled stoked pumped rad",
    sad: "sad cry cried crying tears lost loss lonely alone miss missed grief gloomy blue down hurt hurts hurting broke broken fail failed failing sorrow mourning empty dark goodbye died death dying sorry heartbroken quit tired exhausted stuck terrible awful horrible horrid miserable worst bad rough painful pain ache aching sick sicker ill unwell nausea nauseous vomit puking fever poisoning hospital injury injured suffering depressed depressing hopeless bummed crummy crappy lousy gutted devastated drained",
    anger: "angry mad furious rage hate hated hates annoyed annoying irritated irritating unfair betrayed stupid damn fight fought yell yelled scream screamed slammed revenge outraged insulted cruel fired stole stolen cheated lied lying wrong bug crash crashed error broken frustrated frustrating infuriating ridiculous absurd outrageous rude disrespect disrespected ignored dismissed",
    fear: "afraid fear fears scared terrified terrifying panic panicking worry worried worrying anxious anxiety nervous dread dreading horror creepy danger dangerous threat threatened shaking trembling alarm alarmed risk risky unsure uncertain uneasy paranoid stressed stressing overwhelmed",
    surprise: "surprised surprise surprising sudden suddenly unexpected unexpectedly shock shocked shocking wow whoa gasp gasped unbelievable astonished stunned nowhere really seriously literally insane wild crazy",
    disgust: "disgust disgusted disgusting gross grossed nasty yuck yucky rotten filthy vile revolting foul slimy moldy rancid stinky reeks putrid ew eww"
  };
  var W2E = {};
  Object.keys(LEX).forEach(function (e) { LEX[e].split(" ").forEach(function (w) { W2E[w] = e; }); });
  var NEGATORS = { not: 1, no: 1, never: 1, dont: 1, isnt: 1, wasnt: 1, wont: 1, cant: 1, didnt: 1, nobody: 1 };
  var BOOSTERS = { very: 1, so: 1, really: 1, extremely: 1, incredibly: 1, totally: 1, absolutely: 1, deeply: 1 };
  var FLIP = { joy: "sad", sad: "joy", anger: "joy", fear: "joy", surprise: "surprise", disgust: "joy" };
  var HUMOR = /\b(haha+|lol|lmao|rofl|hilarious|funny|joke|joking|kidding)\b/i;
  var THIRD = /(^|\W)(he|she|they|him|her|them|boss|coworker|neighbor|teacher|doctor|mom|dad|brother|sister|friend|guy|woman|man|dog|cat|everyone|someone)(\W|$)/i;
  var SELF_FEEL = /(^|\W)(i|im|we|my|me|mine|our)(\W|$)|(^|\W)i'?m(\W|$)/i;
  var AT_ME = /\b(at me|to me|on me|about me|against me|my fault)\b/i;
  var HOPE_CUE = /\b(hope|hopes|hoping|hopefully|fingers crossed|cant wait|can'?t wait|looking forward|excited (for|about))\b/i;

  function scoreText(text) {
    var scores = { joy: 0, sad: 0, anger: 0, fear: 0, surprise: 0, disgust: 0 };
    var energy = 1;
    if (/!/.test(text)) energy += 0.5;
    if (/!!+|\?!/.test(text)) energy += 0.5;
    if (/\b[A-Z]{3,}\b/.test(text)) energy += 0.5;
    // contrast: the clause after a but/however is the one that counts
    var clauses = text.split(/\b(?:but|however|though|yet)\b/i);
    clauses.forEach(function (clause, ci) {
      var w = (ci === clauses.length - 1 && clauses.length > 1) ? 2 : 1;
      var toks = clause.toLowerCase().replace(/'/g, "").match(/[a-z]+/g) || [];
      var boost = 1, negate = false;
      toks.forEach(function (t) {
        if (BOOSTERS[t]) { boost = 2; return; }
        if (NEGATORS[t]) { negate = true; return; }
        var emo = W2E[t];
        if (emo) scores[negate ? FLIP[emo] : emo] += w * boost * energy;
        boost = 1; negate = false;
      });
    });
    return scores;
  }
  function domOf(scores) {
    return Object.keys(scores).filter(function (e) { return scores[e] > 0; })
      .sort(function (a, b) { return scores[b] - scores[a]; });
  }

  // gesture vocabulary on the body vars (the 3D rig reads these)
  function bigNod() { gesture("--nod", [9, -3, 7, -2, 0], 140); }
  function tinyNod() { gesture("--nod", [3, 0], 150); }
  function recoil() { gesture("--nod", [-8, 2, -5, 0], 130); }
  function sigh() { gesture("--nod", [5, 8, 4, 0], 260); }
  function shakeZ() { gesture("--rz", [-5, 4, -3, 0], 120); }
  var tiltTimer = null;
  function tiltZ(deg, ms) {
    if (!cube) return;
    cube.style.setProperty("--rz", deg + "deg");
    clearTimeout(tiltTimer);
    tiltTimer = later(setTimeout(function () { if (cube) cube.style.setProperty("--rz", "0deg"); }, ms || 1600));
  }

  // listener responses mapped onto the avatar's real controls
  var RESPONSES = {
    "share-joy":      function (s) { return { mouth: s >= 4 ? "grin" : "smirk", brows: "raised", g: s >= 5 ? bigNod : nod }; },
    "happy-for":      function ()  { return { mouth: "smirk", brows: "raised", g: nod }; },
    "relief":         function ()  { return { mouth: "happy", brows: "raised", g: bigNod }; },
    "satisfaction":   function ()  { return { mouth: "grin", brows: "raised", g: bigNod }; },
    "disappointment": function ()  { return { mouth: "neutral", brows: "worried", tilt: -5, g: sigh }; },
    "fears-confirmed":function ()  { return { mouth: "neutral", brows: "worried", tilt: -4, g: shakeZ }; },
    "downturn":       function ()  { return { mouth: "neutral", brows: "worried", tilt: -4, g: sigh }; },
    "hope":           function ()  { return { mouth: "smirk", brows: "raised", g: tinyNod }; },
    "sympathy":       function ()  { return { mouth: "neutral", brows: "worried", tilt: -6 }; },
    "sympathy-them":  function ()  { return { mouth: "neutral", brows: "worried", tilt: -4 }; },
    "concern":        function (s) { return { mouth: s >= 3 ? "surprised" : "neutral", brows: "worried" }; },
    "indignant":      function ()  { return { mouth: "grim", brows: "angry", g: shakeZ }; },
    "lean-in":        function (s) { return { mouth: s >= 3 ? "surprised" : "neutral", brows: "worried", tilt: 5 }; },
    "mirror-shock":   function (s) { return { mouth: "surprised", brows: "raised", g: s >= 4 ? recoil : nod }; },
    "grossed":        function ()  { return { mouth: "grim", brows: "skeptical", tilt: -5, g: shakeZ }; },
    "laugh":          function ()  { return { mouth: "grin", brows: "raised", g: nod }; },
    "nervous-laugh":  function ()  { return { mouth: "grin", brows: "worried", tilt: 3 }; },
    "curious":        function ()  { return { mouth: "smirk", brows: "skeptical", tilt: 7, g: tinyNod }; },
    "rhet-sympathy":  function ()  { return { mouth: "neutral", brows: "worried", tilt: -6 }; },
    "attentive":      function ()  { return { mouth: "neutral", brows: "raised" }; }
  };
  var KIND_FOR = { joy: "share-joy", sad: "sympathy", anger: "concern", fear: "lean-in", surprise: "mirror-shock", disgust: "grossed" };
  var BIG_GESTURES = { "mirror-shock": 1, "indignant": 1, "laugh": 1, "relief": 1, "grossed": 1 };

  var prospect = { type: null, ttl: 0 };   // hope/fear in the air, across turns
  var utterGestured = false;               // one big gesture max per utterance

  // ── the REAL emotion read: GoEmotions classifier on the BEAM ──
  // /voice/affect returns "label score" lines (~40ms). The lexicon below
  // becomes the FALLBACK when the model is absent; the rule layer (arcs,
  // attribution, questions, humor) always runs on top of either source.
  var GO2EMO = {
    admiration: "joy", amusement: "joy", anger: "anger", annoyance: "anger",
    approval: "joy", caring: "joy", desire: "joy", disappointment: "sad",
    disapproval: "anger", disgust: "disgust", embarrassment: "sad",
    excitement: "joy", fear: "fear", gratitude: "joy", grief: "sad",
    joy: "joy", love: "joy", nervousness: "fear", pride: "joy",
    realization: "surprise", relief: "joy", remorse: "sad", sadness: "sad",
    surprise: "surprise"
  };
  var GO_KIND = {   // labels that name a reaction more precisely than the family
    amusement: "laugh", confusion: "curious", curiosity: "curious",
    disappointment: "disappointment", optimism: "hope", relief: "relief"
  };
  var affectCache = { text: null, top: null };
  function affectOf(text) {
    if (affectCache.text === text) return Promise.resolve(affectCache.top);
    if (typeof fetch === "undefined") return Promise.resolve(null);
    return fetch("/voice/affect", { method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" }, body: text })
      .then(function (r) { return r.status === 200 ? r.text() : ""; })
      .then(function (t) {
        var top = null;
        (t || "").split("\n").some(function (line) {
          var m = line.trim().split(" ");
          if (m.length !== 2) return false;
          var label = m[0], score = parseFloat(m[1]);
          if (label === "neutral" || !(score >= 0.15)) return false;
          top = { label: label, score: score };
          return true;                        // lines arrive score-desc: first hit wins
        });
        affectCache = { text: text, top: top };
        return top;
      })
      .catch(function () { return null; });
  }

  function routeListener(text, isFinal, model) {
    var dom, strength, modelKind = null;
    if (model) {                               // the classifier's read
      dom = GO2EMO[model.label] || null;
      strength = Math.max(1, Math.round(model.score * 6));
      modelKind = GO_KIND[model.label] || null;
    } else {                                   // lexicon fallback
      var scores = scoreText(text);
      var ranked = domOf(scores);
      dom = ranked[0];
      strength = dom ? Math.round(scores[dom]) : 0;
    }

    var isQuestion = /\?\s*$/.test(text.trim());
    var isPast = false;
    try { if (window.nlp) isPast = nlp(text).match("#PastTense").found; } catch (e) {}
    if (!window.nlp) isPast = /\b(\w{3,}ed|lost|died|broke|got|went|was|were|had|fell|left)\b/i.test(text);
    if (isPast && dom && dom !== "joy") strength = Math.max(1, strength - 1);

    var hadHope = prospect.type === "hope" && prospect.ttl > 0;
    var hadFear = prospect.type === "fear" && prospect.ttl > 0;
    var negs = { sad: 1, anger: 1, disgust: 1 };

    var kind;
    if (dom === "joy" && (hadFear || hadHope)) kind = hadHope ? "satisfaction" : "relief";
    else if (dom && negs[dom] && hadHope) kind = "disappointment";
    else if (dom && negs[dom] && hadFear && isPast) kind = "fears-confirmed";
    else if (HUMOR.test(text)) kind = (dom && dom !== "joy" && dom !== "surprise") ? "nervous-laugh" : "laugh";
    else if (isQuestion) {
      kind = (/\b(why me|why does this|what did i do|how could)\b/i.test(text) ||
              (dom && (dom === "sad" || dom === "fear"))) ? "rhet-sympathy" : "curious";
    }
    else if ((HOPE_CUE.test(text) || modelKind === "hope") && (!dom || dom === "joy")) kind = "hope";
    else if (modelKind && !dom) kind = modelKind;
    else if (!dom) kind = "attentive";
    else {
      var other = THIRD.test(text), self = SELF_FEEL.test(text), atMe = AT_ME.test(text);
      if (dom === "anger")     kind = (atMe || (other && !self)) ? "indignant" : "concern";
      else if (dom === "sad")  kind = (other && !self) ? "sympathy-them" : "sympathy";
      else if (dom === "joy")  kind = "share-joy";
      else kind = KIND_FOR[dom];
      // the classifier names some reactions more precisely than the family
      if (modelKind && kind !== "indignant" && kind !== "sympathy-them") kind = modelKind;
    }

    if (isFinal) {           // arcs advance only on the settled utterance
      var resolved = { satisfaction: 1, relief: 1, disappointment: 1, "fears-confirmed": 1 };
      if (resolved[kind]) prospect = { type: null, ttl: 0 };   // the arc landed — consume it
      else if (HOPE_CUE.test(text) || modelKind === "hope") prospect = { type: "hope", ttl: 3 };
      else if (dom === "fear") prospect = { type: "fear", ttl: 3 };
      else if (prospect.ttl > 0) prospect.ttl--;
      else prospect.type = null;
    }
    return { kind: kind, strength: strength };
  }

  function reactToUser(text, partial) {
    affectOf(text).then(function (top) {
      if (!mounted) return;
      applyReaction(text, partial, top);
    });
  }
  function applyReaction(text, partial, model) {
    var r = routeListener(text, !partial, model);
    var spec = (RESPONSES[r.kind] || RESPONSES.attentive)(r.strength);
    mood = spec.mouth;
    setMouth(spec.mouth);
    setBrows(spec.brows);
    if (spec.tilt) tiltZ(spec.tilt, partial ? 1200 : 1800);
    if (spec.g) {
      // partials: only ONE big gesture per utterance (no twitching); the
      // final utterance always lands its gesture
      if (!partial) spec.g();
      else if (BIG_GESTURES[r.kind] && !utterGestured) { utterGestured = true; spec.g(); }
    }
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

  // ────────────────────────── Kokoro (BEAM-native first) ──────────────────────────
  // PRIMARY: the app's own Autopoet.Kokoro engine (Ortex/ONNX in Elixir) via
  // POST /voice/tts — one model on disk, no browser downloads. The Web-Worker
  // Kokoro survives only as a FALLBACK when the server engine is off
  // (missing model files or espeak-ng).
  var kokoro = false, kokoroMode = null;   // "server" | "worker"
  // the SESSION voice engine: "qwen" (premium sidecar) | "kokoro". Locked at
  // stage entry — a voice must never change mid-conversation. Qwen boots
  // fire-and-forget; if it isn't ready by the first line, kokoro owns the
  // whole session and qwen waits for the next one.
  var ttsEngine = "qwen";   // THE engine. Kokoro is permanently retired (owner).
  var ttsVoice = null;      // session voice: {engine:"qwen-clone", voice} | {engine:"qwen-design", persona}
  function lockEngine() {
    // the session speaks with the app's DEFAULT voice — boot its model and
    // wait briefly so the FIRST line is the right voice (silent visemes cover
    // any residual warm-up; there is no fallback voice by design)
    return fetch("/voices/default.json").then(function (r) { return r.json(); })
      .then(function (d) {
        var model = "custom";
        if (d && d.engine === "qwen-clone") { ttsVoice = { engine: "qwen-clone", voice: d.name }; model = "base"; }
        else if (d && d.engine === "qwen-design") { ttsVoice = { engine: "qwen-design", persona: d.name }; model = "design"; }
        fetch("/voice/tts/qwen/boot?model=" + model, { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } }).catch(function () {});
        return new Promise(function (res) {
          var t0 = Date.now();
          (function poll() {
            fetch("/voice/tts/qwen/status").then(function (r) { return r.text(); }).then(function (st) {
              if (st.trim() === "ready" || Date.now() - t0 > 12000) res();
              else setTimeout(poll, 700);
            }).catch(res);
          })();
        });
      })
      .catch(function () {});
  }
  // stage type + TTS gate: voice always speaks; plan starts silent (visemes +
  // karaoke caption still run — perform()'s no-clip path) until toggled on
  var vmode = "voice", tts = true;
  var kWorker = null, kSeq = 0, kPending = {};
  var VOICE_ID = "bf_emma";
  function bootKokoro() {
    if (kokoro) return;
    fetch("/voice/tts/status").then(function (r) { return r.text(); }).then(function (s) {
      s = s.trim();
      if (s.indexOf("ready") === 0) {
        kokoro = true; kokoroMode = "server";
        if (mounted && !playing && vmode === "voice") capStatus("ready — just talk");
      } else if (s === "loading") {
        if (mounted && !playing) capStatus("warming local voice…");
        setTimeout(bootKokoro, 2500);
      } else bootWorker();
    }).catch(bootWorker);
  }
  function bootWorker() {
    if (kWorker) return;
    try {
      kWorker = new Worker("/static/vendor/kokoro-worker.mjs", { type: "module" });
      kWorker.onmessage = function (e) {
        var m = e.data;
        if (m.type === "ready") { kokoro = true; kokoroMode = "worker"; if (mounted && !playing && vmode === "voice") capStatus("ready — just talk"); }
        else if (m.type === "progress") {
          if (mounted && !playing && !kokoro) capStatus("downloading voice model… " + m.pct + "%");
        }
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
  // synthesize one sentence → clip {buffer, duration} | null.
  // Cached per turn: the streaming prewarmer fires clauses while the model is
  // still writing, and perform() then reuses the same in-flight promises.
    var genCache = new Map();
  // narration → the clip texts perform() synthesizes (sentence/clause chunks,
  // bracket-tag prefixes included — they're the cache key, stripped at synth)
  function ttsTexts(narration) {
    var stream = tokenize(narration), words = [], pres = [], pend = "";
    stream.forEach(function (s2) {
      if (s2.dir && PARA_TAG.test(s2.dir)) pend += "[" + s2.dir + "] ";
      else if (s2.word) { pres[words.length] = pend; pend = ""; words.push(s2.word); }
    });
    var sText = [], sN = 0, counts = [], cur = "";
    words.forEach(function (w, i) {
      counts[sN] = (counts[sN] || 0) + 1;
      cur += (cur ? " " : "") + (pres[i] || "") + w;
      if (/[.!?]$/.test(w)) { sText[sN] = cur; cur = ""; sN++; }
    });
    if (cur) sText[sN] = cur;
    return sText;
  }
  // the voice QUERY is captured ONCE per narration (perform start) and rides
  // every clip of that narration — a mid-flight default/lab switch can never
  // mix voices within one speech again
  function voiceQuery() {
    if (ttsVoice && ttsVoice.engine === "qwen-design")
      return "engine=qwen-design&persona=" + encodeURIComponent(ttsVoice.persona || "narrator");
    if (ttsVoice && ttsVoice.engine === "qwen-clone")
      return "engine=qwen-clone&voice=" + encodeURIComponent(ttsVoice.voice || "");
    return "";
  }
  function kokoroGen(text, vq) {
    vq = vq === undefined ? voiceQuery() : vq;
    var key = vq + "|" + text;
    if (genCache.has(key)) return genCache.get(key);
    var p = kokoroGenRaw(text, vq);
    genCache.set(key, p);
    return p;
  }
  // ── STREAMING PLAYBACK: the server emits audio chunks as they decode
  //    (/voice/tts?stream=1, length-prefixed wav frames). Each sentence's
  //    chunks play back-to-back through the analyser (so the live-energy mouth
  //    keeps working) and the FIRST sound lands ~0.8s in, not ~3s. Plan mode's
  //    say is plain text (no inline cue-DSL), so this just speaks + mouths. ──
  var STREAM_TTS = true;
  function streamClip(text, vq) {
    var clean = text.replace(/\[[^\]]+\]\s*/g, "");
    var q = vq === undefined ? voiceQuery() : vq;
    var c = { buffers: [], done: false, total: -1, onChunk: null, whenFirst: null };
    var firstRes;
    c.whenFirst = new Promise(function (r) { firstRes = r; });
    fetch("/voice/tts?stream=1" + (q ? "&" + q : ""), {
      method: "POST",
      headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" },
      body: clean
    }).then(function (resp) {
      if (!resp.ok || !resp.body) { c.done = true; firstRes(); if (c.onChunk) c.onChunk(); return; }
      var reader = resp.body.getReader();
      var acc = new Uint8Array(0), parseSeq = 0;
      function feed(bytes) {
        var m = new Uint8Array(acc.length + bytes.length);
        m.set(acc); m.set(bytes, acc.length); acc = m;
        while (acc.length >= 4) {
          var len = ((acc[0] << 24) | (acc[1] << 16) | (acc[2] << 8) | acc[3]) >>> 0;
          if (acc.length < 4 + len) break;
          var wav = acc.slice(4, 4 + len);
          acc = acc.slice(4 + len);
          ensureAudio();
          // index by PARSE order (decodeAudioData resolves out of order) so
          // chunks always play in sequence — the player reads buffers[idx]
          var seq = parseSeq++;
          actx.decodeAudioData(wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength))
            .then(function (buf) {
              c.buffers[seq] = buf;
              if (seq === 0) firstRes();
              if (c.onChunk) c.onChunk();
            }).catch(function () { if (c.onChunk) c.onChunk(); });
        }
      }
      (function pump() {
        reader.read().then(function (r) {
          if (r.value) feed(r.value);
          if (r.done) { c.total = parseSeq; c.done = true; if (c.onChunk) c.onChunk(); return; }
          pump();
        }).catch(function () { c.total = parseSeq; c.done = true; if (c.onChunk) c.onChunk(); });
      })();
    }).catch(function () { c.done = true; firstRes(); if (c.onChunk) c.onChunk(); });
    return c;
  }
  // speak plain text with streaming: sentences fire together (queue on the one
  // worker → chunks arrive in order), play back-to-back, live-energy mouth,
  // sentence-level caption. Resolves onDone.
  // entry: set up the run, freeze the voice, then stream. onDone via performDone.
  function startStreamSpeak(text, onDone) {
    stopPerform();
    var runId = {};
    playing = runId;
    performDone = onDone || null;
    narrationVoiceLive = voiceQuery();
    logLine("poet", text.replace(/\[[^\]]+\]/g, "").trim());
    stopThink();
    moveTo(0, stageEl.clientHeight * 0.12);
    mood = "smirk"; setMouth("smirk");
    speakStream(text, runId);
  }
  function speakStream(text, runId) {
    var sTexts = ttsTexts(text);
    if (!sTexts.length) { playing = null; var cb0 = performDone; performDone = null; if (cb0) cb0(); return; }
    var clips = sTexts.map(function (t) { return streamClip(t, narrationVoiceLive); });
    var endTime = 0, started = false;
    (async function run() {
      for (var i = 0; i < clips.length && playing === runId; i++) {
        var c = clips[i];
        captionShow("", sTexts[i].replace(/&/g, "&amp;").replace(/</g, "&lt;"));
        await c.whenFirst;
        if (playing !== runId) return;
        var idx = 0;
        function sched() {
          // consume buffers IN ORDER; stop at the first gap (a later chunk may
          // have decoded before an earlier one — wait for the earlier one)
          while (c.buffers[idx] !== undefined) {
            var src = actx.createBufferSource();
            src.buffer = c.buffers[idx];
            src.connect(analyser);
            var at = Math.max(endTime, actx.currentTime + 0.02);
            src.start(at);
            endTime = at + c.buffers[idx].duration;
            clipNow = { src: src, t0: at };
            streamSrcs.push(src);   // tracked so a cut stops queued-ahead audio
            if (!started) { started = true; stopThink(); startMouthLoop(); }
            idx++;
          }
        }
        sched();
        c.onChunk = sched;
        await new Promise(function (res) {
          (function wait() {
            if (playing !== runId) return res();
            if (c.done && c.total >= 0 && idx >= c.total) {
              setTimeout(res, Math.max(0, (endTime - actx.currentTime) * 1000 + 40));
            } else setTimeout(wait, 50);
          })();
        });
      }
      clipNow = null; streamSrcs = [];
      if (playing === runId) { playing = null; var cb = performDone; performDone = null; if (cb) cb(); }
    })();
  }
  function kokoroGenRaw(text, vq) {
    if (true) {   // ONE lane: the server's Qwen engine (kokoro worker retired)
      var q = vq === undefined ? voiceQuery() : vq;
      return fetch("/voice/tts" + (q ? "?" + q : ""), {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "text/plain" },
        body: text.replace(/\[[^\]]+\]\s*/g, "")   // never SAY a stray bracket tag
      }).then(function (r) {
        if (!r.ok) throw new Error("tts " + r.status);
        return r.arrayBuffer();
      }).then(function (ab) {
        ensureAudio();
        return actx.decodeAudioData(ab);
      }).then(function (buf) {
        return { buffer: buf, duration: buf.duration };
      }).catch(function () { return null; });
    }
    return new Promise(function (resolve) {
      if (!kokoro || !kWorker) { resolve(null); return; }
      var id = ++kSeq; kPending[id] = resolve;
      kWorker.postMessage({ type: "gen", id: id, text: text, voice: VOICE_ID });
      later(setTimeout(function () { if (kPending[id]) { delete kPending[id]; resolve(null); } }, 15000));
    }).then(function (raw) { return raw ? makeClip(raw) : null; });
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
  var playing = null, timer = null, performDone = null, narrationVoiceLive = "";
  // the entrance. ADOPT mode (live call from the dashboard): release the self
  // cube from its node footprint and glide it to center stage. STANDALONE mode
  // (onboarding + /voice/widget): the stage owns its own cube — scale it in at
  // center. Either runs at mount OR on demand via board.enter() (held cube).
  function playEntrance(done) {
    if (!mounted) { if (done) done(); return; }
    root.classList.add("on");
    var performer = (vmode === "voice");

    if (adopt && appHooks) {
      var settle = entranceSettle;
      later(setTimeout(function () { appHooks.hideWorld(); }, Math.max(0, settle - 350)));
      later(setTimeout(function () {
        if (!mounted) { if (done) done(); return; }
        var spot = appHooks.selfSpot();
        scene.dataset.free = "1";                       // the app stops node-tracking
        scene.style.setProperty("--toon", "1.6px");     // full-size line while free
        scene.classList.add("vs-free");
        scene.style.transform = "";                     // the class + vars own it now
        scene.style.transition = "none";
        scene.style.setProperty("--sx", spot.sx + "px");
        scene.style.setProperty("--sy", spot.sy + "px");
        scene.style.setProperty("--sc", spot.sc.toFixed(4));
        scene.style.opacity = "";
        stagePos = { x: spot.sx, y: spot.sy };
        void scene.offsetWidth;                         // commit the start frame
        scene.style.transition = "";                    // .vs-free transition resumes
        moveTo(0, 0);                                   // glide to center stage…
        scene.style.setProperty("--sc", "1");           // …growing to full size
        if (performer) { capStatus(kokoro ? "ready — just talk" : "loading local voice…"); startVAD(); }
        later(setTimeout(function () { if (mounted && !playing) wave(); }, 900));
        if (done) later(setTimeout(done, 1150));
      }, settle));
    } else {
      // standalone: the cube pops in at center (scale + fade), then waves
      stagePos = { x: 0, y: 0 };
      if (scene) {
        scene.style.transition = "none";
        scene.style.transformOrigin = "50% 60%";
        scene.style.transform = "scale(.5)";
        scene.style.opacity = "0";
        void scene.offsetWidth;
        scene.style.transition = "opacity .45s ease, transform .62s cubic-bezier(.34,1.5,.4,1)";
        scene.style.transform = "scale(1)";
        scene.style.opacity = "1";
      }
      if (performer) { capStatus(kokoro ? "ready — just talk" : "loading local voice…"); startVAD(); }
      later(setTimeout(function () { if (mounted && !playing) wave(); }, 620));
      if (done) later(setTimeout(done, 900));
    }
  }
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
    stopClip();
    captionHide();
    hideHands();
    if (mounted) moveTo(0, 0);
    mood = "neutral"; setMouth("neutral"); setBrows("none");
  }
  async function perform(script, onDone) {
    stopPerform();
    var runId = {};
    playing = runId;
    performDone = onDone || null;
    var narration = script, g = script.match(/@graph\s*([\s\S]*?)@end/);
    var mm = script.match(/@mermaid\s*([\s\S]*?)@end/);
    // @slide blocks (any number) append to the session deck and take the stage
    var slides = [];
    narration = narration.replace(/@slide\s*([\s\S]*?)@end/g, function (_, s) {
      slides.push(s.trim()); return " ";
    });
    // narration NEVER contains block source, whichever forms appeared —
    // otherwise the avatar would read d2/mermaid syntax aloud
    narration = narration.replace(/@(?:graph|mermaid)\s*[\s\S]*?@end/g, " ");
    if (slides.length) {
      g = null; mm = null;
      for (var si = 0; si < slides.length; si++) {
        try { await deckAdd(slides[si]); }
        catch (e) { captionShow("dim", "(couldn't add the slide)"); }
      }
    }
    if (mm) {
      g = null;
      try { await mountMermaid(mm[1].trim()); }
      catch (e) {
        graphBg.classList.remove("on");
        graphBg.innerHTML = "";
        pieces = { nodes: {}, edges: {} };
        captionShow("dim", "(the diagram didn't compile — talking it through)");
      }
    } else if (g) {
      try { mountGraphSVG(await compileD2(g[1].trim())); }
      catch (e) {
        // failed diagram → clean slate so no cue can point at stale/detached
        // shapes (that was the "pointing above the screen" ghost)
        graphBg.classList.remove("on");
        graphBg.innerHTML = "";
        pieces = { nodes: {}, edges: {} };
        captionShow("dim", "(the diagram didn't compile — talking it through)");
      }
    } else if (!slides.length) {
      // no new board this turn: an existing deck stays (or returns to) the stage
      if (deckMd && boardMode !== "deck") { try { await renderDeck(deckMd); } catch (e) {} }
      else if (!deckMd) showBoard(null);
    }
    if (playing !== runId) return;

    var stream = tokenize(narration);
    var words = [], pres = [], pend = "";
    stream.forEach(function (s) {
      if (s.dir && PARA_TAG.test(s.dir)) { s._para = true; pend += "[" + s.dir + "] "; }
      else if (s.word) { s._wi = words.length; pres[words.length] = pend; pend = ""; words.push(s.word); }
    });
    if (!words.length) { stopPerform(); return; }
    logLine("poet", words.join(" "));

    var sentOf = [], counts = [], sText = [], sN = 0, cur = "";
    words.forEach(function (w, i) {
      sentOf[i] = sN; counts[sN] = (counts[sN] || 0) + 1;
      cur += (cur ? " " : "") + (pres[i] || "") + w;
      // clip boundaries at sentence ends AND clause breaks (,;:) once the
      // clause is ≥5 words: synthesis is ~0.6x realtime, so smaller clips =
      // the first sound arrives after one CLAUSE, not one full sentence
      if (/[.!?]$/.test(w)) {
        sText[sN] = cur; cur = ""; sN++;
      }
    });
    if (cur) sText[sN] = cur;

    // pipeline synthesis: all sentences fired at once, speak on first arrival
    var clips = [], clipP = [];
    var narrationVoice = voiceQuery();   // FROZEN for this whole narration
    if (tts) {
      for (var s = 0; s < sText.length; s++) {
        clipP[s] = kokoroGen(sText[s], narrationVoice);
        clipP[s].then((function (idx) { return function (a) { clips[idx] = a; }; })(s));
      }
      clips[0] = await clipP[0];
      if (playing !== runId) return;
    }

    stopThink();
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
      if (PARA_TAG.test(d)) return;          // voice-only tag — already in the audio
      if (d[0] === "+") reveal(d.slice(1));
      else if (d.indexOf("point ") === 0) {
        var pname = d.slice(6).trim();
        revealNode(pname, false);                       // can't point at nothing
        var gp = pieces.nodes[pname]; if (gp) pointAt(gp, 2200);
      }
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
      else if (/^slide \d+$/.test(d)) deckGoto(parseInt(d.slice(6), 10));
      else if (d === "wave") wave();
      else if (d === "wave2") wave(true);
      else if (d === "thumbsup") thumbsUp();
      else if (d === "shrug") { shrug(); setBrows("raised"); later(setTimeout(function () { setBrows("none"); }, 1300)); }
      else if (d === "nod") nod();
    }

    var sIdx = 0, lastPrewalk = null;
    (async function nextSentence() {
      if (playing !== runId) return;
      if (sIdx >= groups.length) {
        revealAll();   // whatever the cues missed, the finished diagram shows whole
        later(setTimeout(function () {
          if (playing === runId) {
            var cb = performDone; performDone = null;
            stopPerform();
            if (kokoro && vmode === "voice") capStatus("ready — just talk");
            if (cb) cb();   // narration finished → the auto-runner advances
          }
        }, 700));
        return;
      }
      var g2 = groups[sIdx], sentNo = sIdx; sIdx++;
      if (!g2) { nextSentence(); return; }

      var clip = clips[sentNo] !== undefined ? clips[sentNo] : await (clipP[sentNo] || Promise.resolve(null));
      if (playing !== runId) return;

      var durMs = clip ? clip.duration * 1000 : 0;
      if (!durMs) { var wc = g2.items.filter(function (x) { return x.word; }).length; durMs = 260 * wc + 500; }

      var totalW = 0;
      g2.items.forEach(function (x) { if (x.word) totalW += x.word.length + 1; });
      totalW = totalW || 1;
      var acc = 0, trailingPause = 0;
      g2.items.forEach(function (x) {
        x._t = (acc / totalW) * durMs;
        if (x.word) acc += x.word.length + 1;
        else if (x.dir && x.dir.indexOf("pause ") === 0) trailingPause = +x.dir.slice(6) || 0;
      });

      if (clip) playClip(clip, function () { go(); });   // sound + mouth + advance-on-end
      else audioDriven = false;                          // silent sentence → text-cadence mouth

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
      function go() {
        if (advanced || playing !== runId) return;
        advanced = true;
        later(setTimeout(nextSentence, trailingPause + 120));
      };
      if (clip) timer = later(setTimeout(go, durMs + 1500));   // playClip advances on end; this is the safety net
      else timer = later(setTimeout(go, durMs + trailingPause));
    })();
  }

  // ────────────────────────── the conversation loop ──────────────────────────
  var history = [];
  // ── the thinking beat: cloud + upward gaze while the brain works ──
  // classic scalloped thought-cloud (ink outline, typing dots, trail puffs)
  var THINK_CLOUD =
    '<svg viewBox="0 0 104 78" fill="none">' +
    '<path d="M30 18 C33 8 47 4 54 10 C58 2 74 2 78 10 C88 6 98 14 94 23 C102 27 102 39 94 43 C96 52 86 58 78 54 C74 62 58 62 53 55 C45 61 31 57 30 48 C20 50 12 42 16 34 C8 30 10 20 18 18 C20 14 26 14 30 18 Z" ' +
    'fill="#fff" stroke="#121316" stroke-width="2.2" stroke-linejoin="round"/>' +
    '<circle class="dot" cx="41" cy="32" r="4" fill="#121316"/>' +
    '<circle class="dot" cx="55" cy="32" r="4" fill="#121316"/>' +
    '<circle class="dot" cx="69" cy="32" r="4" fill="#121316"/>' +
    '<ellipse cx="22" cy="64" rx="6.5" ry="5" fill="#fff" stroke="#121316" stroke-width="2"/>' +
    '<ellipse cx="11" cy="74" rx="4" ry="3" fill="#fff" stroke="#121316" stroke-width="1.8"/>' +
    '</svg>';
  function startThink() {
    if (!mounted) return;
    var tk = document.getElementById("vs-think");
    if (tk) tk.classList.add("on");
    setBrows("skeptical");
    setMouth("neutral");
    // eyes drift up toward the cloud
    var r = scene && scene.getBoundingClientRect();
    if (r) setAttention({ x: r.right - 10, y: r.top - 40 }, 8000, 1.4);
  }
  function stopThink() {
    var tk = document.getElementById("vs-think");
    if (tk) tk.classList.remove("on");
  }

  // ── streaming prewarm: as the model writes, complete clauses go to the
  //    synth and a completed @graph block goes to d2 — perform() then finds
  //    everything already in flight. Mirrors perform's clip-boundary rule.
  function prewarmFromPartial(text) {
    // fire what can be fired early: d2 compiles, the deck/mermaid libs warm
    var gm = text.match(/@graph\s*([\s\S]*?)@end/);
    if (gm) compileD2(gm[1].trim());
    if (/@mermaid|@slide/.test(text)) { ensureMermaid(); ensureReveal(); }
    // narration = text minus complete blocks, cut at any dangling opener
    var narration = text.replace(/@(?:slide|graph|mermaid)\s*[\s\S]*?@end/g, " ");
    var open = narration.search(/@(?:slide|graph|mermaid)/);
    if (open > -1) narration = narration.slice(0, open);
    // keep sound tags (they're part of the TTS text), drop stage cues —
    // MUST build clauses exactly like perform() or the prewarm cache misses
    narration = narration.replace(/\[([^\]]*)\]/g, function (_, d) {
      d = d.trim();
      // inner spaces protected so "[clear throat]" survives the token split
      return PARA_TAG.test(d) ? "\u0001" + d.replace(/ /g, "\u0003") + "\u0002" : " ";
    }).replace(/\[[^\]]*$/, " ");
    var toks = narration.split(/\s+/).filter(Boolean);
    var cur = [], n = 0, first = true, pend2 = "";
    toks.forEach(function (w, i) {
      if (w[0] === "\u0001") { pend2 += "[" + w.slice(1, -1).replace(/\u0003/g, " ") + "] "; return; }
      cur.push(pend2 + w); pend2 = "";
      n++;
      var boundary = /[.!?]$/.test(w) || (/[,;:]$/.test(w) && n >= (first ? 3 : 5));
      // never prewarm the trailing fragment — it may still be growing
      if (boundary && i < toks.length - 1) {
        if (kokoro) kokoroGen(cur.join(" "));
        cur = []; n = 0; first = false;
      }
    });
  }

  async function ask(userText) {
    userText = (userText || "").trim();
    if (!userText || !mounted) return;
    captionShow("you", userText);
    logLine("you", userText);
    reactToUser(userText);
    history.push({ role: "user", content: userText });
    genCache.clear(); d2Cache.clear();
    startThink();
    var ctrl = new AbortController();
    var killer = later(setTimeout(function () { ctrl.abort(); }, 45000));
    try {
      var reply = await brainStream(ctrl.signal);
      clearTimeout(killer);
      if (reply == null) {                                 // stream route unavailable
        reply = await brainOnce(ctrl.signal);
        clearTimeout(killer);
      }
      if (reply == null) return;
      history.push({ role: "assistant", content: reply });
      await perform(reply);
    } catch (err) {
      clearTimeout(killer);
      stopThink();
      capStatus("brain unreachable");
      mood = "neutral"; setMouth("neutral"); setBrows("none");
    }
  }

  // SSE from /voice/brain/stream — returns the full reply text (prewarming as
  // it goes), or null if the route is unavailable (older server → fallback)
  async function brainStream(signal) {
    var res;
    try {
      res = await fetch("/voice/brain/stream", { method: "POST", signal: signal,
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify({ history: history.slice(-16) }) });
    } catch (e) { return null; }
    if (!res.ok || !res.body) return null;
    var reader = res.body.getReader(), dec = new TextDecoder();
    var buf = "", full = "", lastWarm = 0;
    for (;;) {
      var step = await reader.read();
      if (step.done) break;
      buf += dec.decode(step.value, { stream: true });
      var lines = buf.split("\n");
      buf = lines.pop();                                   // keep the partial line
      lines.forEach(function (line) {
        if (line.indexOf("data:") !== 0) return;
        var payload = line.slice(5).trim();
        if (!payload || payload === "[DONE]") return;
        try {
          var delta = JSON.parse(payload).choices[0].delta.content;
          if (delta) full += delta;
        } catch (e) {}
      });
      if (full.length - lastWarm > 24) {                   // warm every ~24 chars
        lastWarm = full.length;
        prewarmFromPartial(full);
      }
    }
    if (!full) return null;
    prewarmFromPartial(full);
    return full.trim();
  }

  async function brainOnce(signal) {
    var res = await fetch("/voice/brain", { method: "POST", signal: signal,
      headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ history: history.slice(-16) }) });
    if (!res.ok) {
      var e = await res.json().catch(function () { return {}; });
      stopThink();
      capStatus(e.error || ("brain error " + res.status));
      mood = "neutral"; setMouth("neutral"); setBrows("none");
      return null;
    }
    var data = await res.json();
    return data.reply;
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
      if (!window.nlp) await loadScript("/static/vendor/compromise.min.js");   // deep listener NLP
    })();
    return depsReady;
  }
  async function startVAD() {
    try {
      await ensureDeps();
      if (!window.vad) { capStatus("voice detection unavailable — type in the transcript"); return; }
      // ── LIVE lane: moonshine re-transcribes the growing utterance every
      //    ~700ms while you're still talking — live blue caption + realtime
      //    emotional reactions. The final full-accuracy pass runs at speech end.
      var speechFrames = [], collecting = false, partialTimer = null, partialBusy = false, lastPartial = "";
      function partialTick() {
        if (!mounted || !collecting || partialBusy || !speechFrames.length) return;
        partialBusy = true;
        var total = 0;
        for (var i = 0; i < speechFrames.length; i++) total += speechFrames[i].length;
        var buf = new Float32Array(total), off = 0;
        for (var j = 0; j < speechFrames.length; j++) { buf.set(speechFrames[j], off); off += speechFrames[j].length; }
        var blob = wavFromRaw({ audio: buf, sampling_rate: 16000 });
        fetch("/voice/dictate/live", { method: "POST",
          headers: { authorization: "Bearer " + TOKEN, "content-type": "audio/wav" }, body: blob })
          .then(function (r) { return r.status === 200 ? r.text() : ""; })
          .then(function (t) {
            partialBusy = false;
            t = (t || "").trim();
            if (!t || !collecting || !mounted) return;
            captionShow("you", t);                     // your words, as you say them
            if (t !== lastPartial) { lastPartial = t; reactToUser(t, true); }
          })
          .catch(function () { partialBusy = false; });
      }
      micVad = await vad.MicVAD.new({
        baseAssetPath: "/static/vendor/", onnxWASMBasePath: "/static/vendor/",
        onFrameProcessed: function (probs, frame) {
          if (collecting && frame && frame.length) speechFrames.push(new Float32Array(frame));
        },
        onSpeechStart: function () {
          if (!mounted) return;
          stopThink();
          if (playing) stopPerform();                  // barge-in
          setBrows("raised");
          captionShow("you", "…");
          speechFrames = []; lastPartial = ""; collecting = true;
          utterGestured = false;                       // one big gesture per utterance
          clearInterval(partialTimer); clearTimeout(partialTimer);
          // first partial lands ~350ms in (feels immediate), then 500ms cadence
          partialTimer = later(setTimeout(function () {
            partialTick();
            partialTimer = later(setInterval(partialTick, 500));
          }, 350));
        },
        onSpeechEnd: async function (audio) {
          collecting = false;
          clearInterval(partialTimer); clearTimeout(partialTimer);
          if (!mounted) return;
          if (lastPartial) captionShow("you", lastPartial);
          else captionShow("dim", "transcribing…");
          var blob = wavFromRaw({ audio: audio, sampling_rate: 16000 });
          try {
            var r = await fetch("/voice/dictate", { method: "POST",
              headers: { authorization: "Bearer " + TOKEN, "content-type": "audio/wav" }, body: blob });
            var text = (await r.text()).trim();
            if (r.ok && text && !/^refused:/.test(text)) ask(text);
            else if (lastPartial) ask(lastPartial);    // the live lane already heard you
            else { captionHide(); capStatus("didn't catch that"); }
          } catch (e) {
            if (lastPartial) ask(lastPartial);
            else { captionHide(); capStatus("transcription failed"); }
          }
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
    // the white grid paper shows for any STANDALONE stage (no graph behind it) —
    // that includes onboarding, which adopts the real cube but has no live graph
    root.innerHTML =
      (appHooks ? '' : '<div class="vs-paper"></div>') +
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
    // the whiteboard AND the paper must paint BELOW the avatar (the performer
    // walks in front of the board, never behind it) — pull both out of
    // vs-root's stacking context: paper 1 < board 3 < cube 5 < root 6
    var gbEsc = root.querySelector("#vs-graph-bg");
    if (gbEsc) stageEl.insertBefore(gbEsc, root);
    var paperEsc = root.querySelector(".vs-paper");
    if (paperEsc) stageEl.insertBefore(paperEsc, gbEsc || root);

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
      // the thought cloud rides the adopted cube's container
      var tk = document.createElement("div");
      tk.id = "vs-think";
      tk.innerHTML = THINK_CLOUD;
      scene.appendChild(tk);
      // hands join the adopted cube (they ride its 3D transform)
      var hr = document.createElement("div"); hr.className = "vs-hand"; hr.id = "vs-hand-r";
      var hl = document.createElement("div"); hl.className = "vs-hand left"; hl.id = "vs-hand-l";
      cube.appendChild(hr); cube.appendChild(hl);
      hands = { r: hr, l: hl };
    } else {
      cube = document.getElementById("vs-cube");
      scene = document.getElementById("vs-scene");
      var tk2 = document.createElement("div");
      tk2.id = "vs-think";
      tk2.innerHTML = THINK_CLOUD;
      scene.appendChild(tk2);
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
  var entranceSettle = 600;
  var _spinRAF = null, _spinDeg = 0, _spinStop = false;   // beam/land spin state
  // ── THE STAGE — one entrance, two types ────────────────────────────────────
  //   type:"voice" — the full call: mic (Moonshine VAD), Kokoro TTS, the brain.
  //   type:"plan"  — the SAME stage + performer (adopted cube, hands, pointAt,
  //                  D2 whiteboard, captions) with NO audio; returns the verbs
  //                  plan mode drives ({show, reveal, point, say, …}).
  // Same avatar by construction: both types adopt the app's real self cube.
  function stage(opts) {
    // self-heal: if a previous call crashed mid-flight, `mounted` can be stuck
    // true with the overlay gone — the button would silently do nothing forever
    if (mounted && !document.getElementById("vs-root")) {
      mounted = false;
      clearAll();
      root = null; overlay = null; hands = null; caption = null; drawer = null; drawerLog = null; graphBg = null;
      appHooks = null; adopt = null;
    }
    if (mounted) return null;
    exitTimers.forEach(clearTimeout); exitTimers = [];
    opts = opts || {};
    var mode = opts.type || "voice";
    var voice = mode === "voice";
    vmode = mode;
    tts = voice ? true : opts.tts !== false;
    TOKEN = opts.token || TOKEN;
    stageEl = opts.stage || document.getElementById("stage");
    callbarEl = opts.callbar || (voice ? document.getElementById("callbar") : null);
    callinEl = opts.callin || (voice ? document.getElementById("callin") : null);
    adopt = opts.adopt || null;
    entranceSettle = opts.settleMs !== undefined ? opts.settleMs : 600;
    appHooks = (opts.selfSpot && opts.hideWorld && opts.showWorld)
      ? { selfSpot: opts.selfSpot, hideWorld: opts.hideWorld, showWorld: opts.showWorld,
          resync: opts.resync || function () {} }
      : null;
    injectCSS();
    buildDOM();
    mounted = true;
    lockEngine();
    deckMd = ""; deckResetLocal();
    if (voice) {
      fetch("/voice/deck/new", { method: "POST",
        headers: { authorization: "Bearer " + TOKEN } }).catch(function () {});
      ensureAudio();   // created + resumed INSIDE the button gesture — sound works
    }
    startBlink();
    startGaze();
    bootKokoro();   // both types: plan speaks by default (tts opt-out)

    // HOLD MODE (onboarding): the grid comes up but the cube waits offstage
    // while the requisition form is filled — board.beam()/land() do the rest.
    // "standalone" = anything that isn't a live graph call (no appHooks): it
    // owns the whiteboard grid, whether it adopts the real cube or not.
    var standalone = !appHooks;
    if (standalone) stageEl.classList.add("vs-whiteboard");
    if (opts.hold) {
      root.classList.add("on");
      if (adopt && appHooks) appHooks.hideWorld();
      stagePos = { x: 0, y: 0 };
      if (scene) scene.style.opacity = "0";               // cube waits for enter()
    } else {
      // adopt+appHooks → release from the self node; else → cube pops in
      playEntrance();
    }

    if (voice) return null;
    // plan type: hand back the performance verbs (no audio anywhere in the path)
    var escT = function (s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;"); };
    return {
      show: function (src) { return compileD2(src).then(function (svg) { if (mounted) mountGraphSVG(svg); }); },
      reveal: function (spec) { if (mounted) reveal(spec); },
      revealAll: function () { if (mounted) revealAll(); },
      point: function (name, ms) {
        if (!mounted) return;
        var t = pieces.nodes[name] || pieces.edges[name];
        if (t) pointAt(t, ms || 2600);
      },
      // held-cube entrance: adopt → float in from the self-node footprint;
      // standalone → pop in at center. Resolves once arrived + waved.
      enter: function () {
        return new Promise(function (res) {
          if (!mounted) { res(); return; }
          playEntrance(res);
        });
      },
      // BEAM: the SAME cube (WebGL body) drops to center, faceless, and slowly
      // spins (via --ry, which Avatar3D reads) while the voice warms — a loading
      // bar sits beneath it. Component-agnostic: drives whatever cube is mounted.
      beam: function () {
        if (!mounted || !scene) return;
        stagePos = { x: 0, y: 0 };
        scene.classList.add("vs-free");           // centered, --sx/--sy/--sc drive it
        scene.dataset.free = "1";
        scene.classList.add("vs-faceless");       // no face while warming
        scene.style.opacity = "1";
        scene.style.transition = "none";
        scene.style.transform = "";               // kill the graph-tracker's inline
        scene.style.setProperty("--toon", "1.6px");   // transform — class + vars own it now
        scene.style.setProperty("--sx", "0px");
        scene.style.setProperty("--sy", "-46px");
        scene.style.setProperty("--sc", "0.34");
        void scene.offsetWidth;
        scene.style.transition = "";
        scene.style.setProperty("--sy", "0px");   // drop to center
        scene.style.setProperty("--sc", "0.86");
        // slow spin: keep raising --ry; Avatar3D lerps the body toward it
        _spinDeg = 0;
        (function spin() {
          if (!mounted || _spinStop) return;
          _spinDeg += 3.2;
          cube.style.setProperty("--ry", _spinDeg.toFixed(1));
          _spinRAF = requestAnimationFrame(spin);
        })();
        var lb = document.getElementById("vs-loadbar");
        if (!lb) { lb = document.createElement("div"); lb.id = "vs-loadbar"; lb.innerHTML = "<i></i>"; stageEl.appendChild(lb); }
        requestAnimationFrame(function () { lb.classList.add("on"); });
      },
      // LAND: the fast loopy finish + wham. A serious voice SNAPS (short, no
      // overshoot); a lively one SPRINGS (a bouncy scale overshoot). The spin
      // unwinds to front, the face wakes, it waves.
      land: function (o) {
        o = o || {};
        return new Promise(function (res) {
          if (!mounted || !scene) { res(); return; }
          _spinStop = true; if (_spinRAF) cancelAnimationFrame(_spinRAF);
          var lb = document.getElementById("vs-loadbar");
          if (lb) { lb.classList.remove("on"); later(setTimeout(function () { if (lb.parentNode) lb.remove(); }, 320)); }
          var dur = o.snap ? 460 : 900;
          // "loopy motion back to where it is": unwind --ry to 0 (Avatar3D
          // glides the body home fast), then settle at front — no backspin bug
          cube.style.setProperty("--ry", "0");
          scene.style.transition = "transform " + dur + "ms cubic-bezier(.3,1.5,.4,1)";
          scene.classList.remove("vs-faceless");            // wake the face
          setMouth("smirk");
          // scale: snap straight to 1; spring overshoots then settles (the wham)
          if (o.snap) {
            scene.style.setProperty("--sc", "1");
          } else {
            scene.style.setProperty("--sc", "1.12");
            later(setTimeout(function () { scene.style.transition = "transform .3s cubic-bezier(.4,0,.3,1)"; scene.style.setProperty("--sc", "1"); }, dur - 120));
          }
          later(setTimeout(function () {
            _spinStop = false; _spinDeg = 0;
            if (mounted && !playing) wave();
            res();
          }, dur + 60));
        });
      },
      // warm the FIRST clip of a line and resolve when it's ready to play —
      // ties the beam animation's length to real synth readiness
      warmFirst: function (text) {
        // streaming synthesizes fast on say() itself — a batch pre-gen here
        // would DOUBLE-generate and fight the stream for the one GPU
        if (STREAM_TTS && tts) return Promise.resolve();
        if (!tts) return Promise.resolve();
        var vq = voiceQuery();
        var parts = ttsTexts(text);
        if (!parts.length) return Promise.resolve();
        ttsTexts(text).forEach(function (t) { kokoroGen(t, vq); });   // warm the rest too
        return Promise.resolve(kokoroGen(parts[0], vq)).catch(function () {});
      },
      say: function (text) {
        return new Promise(function (res) {
          if (!mounted) { res(); return; }
          // STREAM when speaking aloud (sub-second first audio); the silent
          // path (tts off) keeps perform()'s text-cadence visemes
          if (STREAM_TTS && tts && kokoro) startStreamSpeak(text, res);
          else perform(text, res);
        });
      },
      caption: function (text) { if (mounted) captionShow("", escT(text)); },
      status: function (text) { if (mounted) capStatus(text); },
      // the thinking beat — cloud + upward gaze while the brain works
      // (perform() clears it automatically when the next line starts)
      think: function (on) { if (mounted) (on !== false ? startThink() : stopThink()); },
      // ── the deck: the character authors reveal.js slides (the "pitch"); the
      //    accumulated markdown is the plan artifact. slide() appends + shows.
      slide: function (md) { return mounted ? deckAdd(md) : Promise.resolve(); },
      deckReset: function () {
        deckResetLocal();
        return fetch("/voice/deck/new", { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } }).catch(function () {});
      },
      deckGoto: function (n) { deckGoto(n); },
      deckPrev: function () { deckShow(deckCur - 1); },
      deckNext: function () { deckShow(deckCur + 1); },
      deckCount: function () { return deckSlides.length; },
      setTTS: function (on) { tts = !!on; if (tts) bootKokoro(); return tts; },
      ttsOn: function () { return tts; },
      ready: function () { return kokoro; },
      warm: function (text) {
        if (!tts || (STREAM_TTS && tts)) return;   // streaming self-warms on say()
        var vq = voiceQuery();
        ttsTexts(text).forEach(function (t) { kokoroGen(t, vq); });
      },
      wave: function () { if (mounted) wave(); },
      nod: function (amp) {
        if (!mounted) return;
        var a = amp == null ? 1 : amp;
        gesture("--nod", [6 * a + 3, -2 * a, 4 * a + 1, 0], 130);
      },
      thumbsUp: function () { if (mounted) thumbsUp(); },
      // ── behavior-lane puppet verbs (the playground + pose engine drive these) ──
      playTake: function (url) {
        if (!mounted) return Promise.resolve();
        ensureAudio();
        return fetch(url).then(function (r) { return r.arrayBuffer(); })
          .then(function (ab) { return actx.decodeAudioData(ab); })
          .then(function (buf) {
            return new Promise(function (res) {
              playClip({ buffer: buf, duration: buf.duration }, res);
              startMouthLoop();
            });
          });
      },
      setVoice: function (spec) {
        ttsVoice = spec || null;
        genCache.clear();
        var model = spec && spec.engine === "qwen-clone" ? "base"
                  : spec && spec.engine === "qwen-design" ? "design" : null;
        if (model) fetch("/voice/tts/qwen/boot?model=" + model, { method: "POST",
          headers: { authorization: "Bearer " + TOKEN } }).catch(function () {});
        return ttsVoice;
      },
      getVoice: function () { return ttsVoice; },
      energy: function () { return liveEnergy; },
      speaking: function () { return clipNow != null; },
      eyes: function (open) { if (mounted) setEyes(!!open); },
      tilt: function (deg, ms) {
        if (!mounted) return;
        cube.style.setProperty("--rz", deg + "deg");
        later(setTimeout(function () { if (cube) cube.style.setProperty("--rz", "0deg"); }, ms || 900));
      },
      mood: function (k) { if (mounted && MOODS[k]) { mood = MOODS[k][0]; setMouth(MOODS[k][0]); setBrows(MOODS[k][1]); } },
      lookAt: function (x, y, ms) { if (mounted) setAttention({ x: x, y: y }, ms || 1200, 2); },
      moveBy: function (dx, dy) { if (mounted) moveTo(stagePos.x + dx, stagePos.y + dy); },
      exit: exit
    };
  }

  // back-compat: the voice call's historical entrance
  function enter(opts) { stage(Object.assign({}, opts || {}, { type: "voice" })); }

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
        var gbEl = document.getElementById("vs-graph-bg");
        if (gbEl && gbEl.parentNode) gbEl.parentNode.removeChild(gbEl);
        var ppEl = stageEl && stageEl.querySelector(".vs-paper");
        if (ppEl && ppEl.parentNode) ppEl.parentNode.removeChild(ppEl);
        if (oRef && oRef.parentNode) oRef.parentNode.removeChild(oRef);
        if (adopted && handRefs) {
          [handRefs.r, handRefs.l].forEach(function (h) {
            if (h && h.parentNode) h.parentNode.removeChild(h);
          });
        }
        var tkEl = document.getElementById("vs-think");
        if (tkEl && tkEl.parentNode) tkEl.parentNode.removeChild(tkEl);
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
      var gb = document.getElementById("vs-graph-bg");
      if (gb) gb.classList.remove("on");

      var spot = hooks.selfSpot();
      sceneRef.style.transition = "transform .65s cubic-bezier(.4,.9,.4,1)";
      sceneRef.style.setProperty("--sx", spot.sx + "px");
      sceneRef.style.setProperty("--sy", spot.sy + "px");
      sceneRef.style.setProperty("--sc", spot.sc.toFixed(4));
      exitTimers.push(setTimeout(function () { hooks.showWorld(); }, 480));
      exitTimers.push(setTimeout(function () {
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
      }, 680));
      cleanup(1150);
    } else {
      stageEl.classList.remove("vs-whiteboard");
      if (rootRef) rootRef.classList.remove("on");
      // standalone that ADOPTED the real cube (onboarding): release our hold on
      // it so the app can resume it (a reload usually follows, but be clean)
      if (adopted && sceneRef) {
        _spinStop = true; if (_spinRAF) cancelAnimationFrame(_spinRAF);
        sceneRef.classList.remove("vs-faceless", "vs-free");
        sceneRef.dataset.free = "0";
        ["--sx", "--sy", "--sc"].forEach(function (v) { sceneRef.style.removeProperty(v); });
        if (cube) cube.style.removeProperty("--ry");
      }
      cleanup(500);
    }
  }

  // preload: call at app boot so the voice model downloads before the first call
  window.VoiceStage = { stage: stage, enter: enter, exit: exit, ask: ask, preload: bootKokoro };
})();
