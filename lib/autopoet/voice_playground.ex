defmodule Autopoet.VoicePlayground do
  @moduledoc """
  The behavior playground (`GET /voices/playground`) — the REAL avatar (the
  WebGL body via avatar3d.mjs + the real face svg/mouths), driven by
  EVENT-DRIVEN behaviors, not continuous noise:

    1. end-tilt   — cocks its head + closes its eyes at sentence end (p, strength)
    2. affirm-nod — nods after affirmations (p, strength)
    3. idle set   — a repertoire of distinct idle animations, weighted
    4. attention  — how often gaze switches board ↔ you
    5. talk-motion — how much (and in which MIX of ways) it moves while talking

  Sentence ends are detected from the take's live RMS (silence gap); manual
  fire buttons let you feel any behavior instantly. Per-voice parameters are
  initialized from the derived traits and slider-tunable live. This is the
  behavior table the voice stage adopts (where sentence ends and affirmations
  come from the REAL clip boundaries + text, not silence detection).
  """

  def html do
    traits =
      for name <- Autopoet.VoicePersonas.names() ++ Autopoet.VoiceRoster.pinned(),
          t = Autopoet.VoiceRoster.traits(name),
          t != nil,
          File.exists?(Path.join(Autopoet.VoiceRoster.takes_dir(), name <> ".wav")),
          into: %{},
          do: {name, t}

    ~s"""
    <!doctype html><meta charset="utf-8"><title>behavior playground</title>
    <style>
      body{font:14px/1.6 ui-monospace,Menlo,monospace;background:#f7f6f1;color:#16161a;margin:0;
        display:grid;grid-template-columns:320px 1fr;height:100vh}
      #side{padding:22px 20px;border-right:1px solid #e2e6ec;overflow-y:auto;background:#fff}
      h1{font-size:15px;margin:0 0 4px}.sub{color:#6a6f68;font-size:11px;margin-bottom:14px}
      select{appearance:none;-webkit-appearance:none;width:100%;font:600 12.5px ui-monospace,monospace;
        padding:8px 12px;border:1.4px solid #d6dbe2;border-radius:10px;background:#fff;cursor:pointer}
      .lbl{font:600 9.5px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.07em;color:#8a8f88;margin:16px 0 5px}
      .tr{display:flex;align-items:center;gap:8px;font:10.5px ui-monospace,monospace;color:#6a6f68;margin:3px 0}
      .tr span{width:104px;flex:none}
      .tr input{flex:1;accent-color:#16161a}
      .fire{display:flex;gap:8px;margin-top:6px}
      .fire button{font:600 10.5px ui-monospace,monospace;padding:6px 12px;border-radius:8px;
        border:1px solid #d6dbe2;background:#fff;cursor:pointer}
      .fire button:hover{background:#16161a;color:#fff}
      audio{width:100%;margin-top:14px}
      #meter{height:6px;background:#eef0f2;border-radius:3px;margin-top:8px;overflow:hidden}
      #meter i{display:block;height:100%;width:0;background:#16161a}
      #stage{position:relative;overflow:hidden;
        background-image:linear-gradient(#eef1f5 1px,transparent 1px),linear-gradient(90deg,#eef1f5 1px,transparent 1px);
        background-size:24px 24px}
      #board{position:absolute;left:14%;top:26%;width:150px;height:96px;border:1.6px solid #c9cfd8;
        border-radius:12px;background:#fff;display:grid;place-items:center;font:11px ui-monospace,monospace;color:#8a8f88}
      #scene{position:absolute;left:50%;top:55%;width:132px;height:132px;margin:-66px 0 0 -66px;
        transform:translate(var(--sx,0px),var(--sy,0px))}
      #cube{position:absolute;inset:0;
        transform:rotateX(var(--rx,0deg)) rotateY(var(--ry,0deg)) rotateZ(var(--rz,0deg)) rotateX(var(--br,0deg)) scale(var(--sc,1))}
      .sc-face{position:absolute;inset:0;display:grid;place-items:center;pointer-events:none}
      .sc-face svg{width:100%;height:100%}
    </style>
    <div id="side">
      <h1>behavior playground · real avatar</h1>
      <p class="sub">event-driven, not noise: behaviors fire on speech structure. play the take — sentence ends are detected from silence gaps.</p>
      <div class="lbl">voice</div>
      <select id="voice"></select>
      <div class="lbl">1 · end of sentence — head-cock + eye-close</div>
      <div class="tr"><span>probability</span><input type="range" id="et-p" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>strength</span><input type="range" id="et-s" min="0" max="1" step="0.05"></div>
      <div class="lbl">2 · affirmation nod</div>
      <div class="tr"><span>probability</span><input type="range" id="an-p" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>strength</span><input type="range" id="an-s" min="0" max="1" step="0.05"></div>
      <div class="lbl">3 · idle repertoire (weights)</div>
      <div class="tr"><span>still + breathe</span><input type="range" id="id-still" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>look around</span><input type="range" id="id-look" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>micro-tilt</span><input type="range" id="id-tilt" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>slow blink</span><input type="range" id="id-blink" min="0" max="1" step="0.05"></div>
      <div class="lbl">4 · attention — board ↔ you</div>
      <div class="tr"><span>switch rate</span><input type="range" id="at-rate" min="0" max="1" step="0.05"></div>
      <div class="lbl">5 · talk motion (mix × amount)</div>
      <div class="tr"><span>amount</span><input type="range" id="tm-amt" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>sway</span><input type="range" id="tm-sway" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>bob on beats</span><input type="range" id="tm-bob" min="0" max="1" step="0.05"></div>
      <div class="tr"><span>lean in</span><input type="range" id="tm-lean" min="0" max="1" step="0.05"></div>
      <div class="lbl">fire by hand</div>
      <div class="fire">
        <button id="f-end">sentence end</button>
        <button id="f-affirm">affirmation</button>
        <button id="f-switch">switch attention</button>
      </div>
      <audio id="take" controls preload="none"></audio>
      <div id="meter"><i></i></div>
    </div>
    <div id="stage">
      <div id="board">the thing we're<br>talking about</div>
      <div id="scene"><div id="cube" class="sc-cube"><div class="sc-face" id="facemount"></div></div></div>
    </div>
    <script type="module">
      import "/static/vendor/avatar3d.mjs";
      const TRAITS = #{Jason.encode!(traits)};

      // ── the REAL avatar: WebGL body + the real face svg + real mouths ──
      const scene = document.getElementById("scene");
      const cube = document.getElementById("cube");
      window.Avatar3D.mount(scene, cube);
      const faceText = await (await fetch("/avatar")).text();
      const MOUTHS = await (await fetch("/avatar/mouths.json")).json();
      const doc = new DOMParser().parseFromString(faceText.replace(/ap-/g, "pgap-"), "image/svg+xml");
      const fsvg = document.importNode(doc.documentElement, true);
      fsvg.setAttribute("width", "100%"); fsvg.setAttribute("height", "100%");
      document.getElementById("facemount").appendChild(fsvg);
      const el = s => document.getElementById("pgap-" + s);
      const setMouth = k => { const m = el("mouth"); if (m && MOUTHS[k]) m.innerHTML = MOUTHS[k]; };
      const setEyes = open => { const e = el("eyes-open"), c = el("eyes-closed");
        if (e) e.style.display = open ? "" : "none"; if (c) c.style.display = open ? "none" : ""; };

      // ── parameters: initialized from the voice's traits, tuned by sliders ──
      let P = {};
      const fromTraits = t => ({
        etP: (t.playfulness ?? .5) * .8, etS: .35 + (t.warmth ?? .5) * .55,
        anP: (t.dominance ?? .5) * .75, anS: .3 + (t.dominance ?? .5) * .6,
        idStill: (t.steadiness ?? .5), idLook: (t.energy ?? .5) * .8,
        idTilt: (t.playfulness ?? .5) * .6, idBlink: .3 + (1 - (t.energy ?? .5)) * .4,
        atRate: .2 + (t.energy ?? .5) * .5,
        tmAmt: (t.energy ?? .5) * .5 + (t.expanse ?? .5) * .4,
        tmSway: (t.playfulness ?? .5), tmBob: (t.energy ?? .5), tmLean: (t.dominance ?? .5)
      });
      const SLIDERS = { "et-p": "etP", "et-s": "etS", "an-p": "anP", "an-s": "anS",
        "id-still": "idStill", "id-look": "idLook", "id-tilt": "idTilt", "id-blink": "idBlink",
        "at-rate": "atRate", "tm-amt": "tmAmt", "tm-sway": "tmSway", "tm-bob": "tmBob", "tm-lean": "tmLean" };
      function syncSliders() {
        for (const [id, k] of Object.entries(SLIDERS)) {
          const i = document.getElementById(id); i.value = P[k]; i.oninput = () => P[k] = +i.value;
        }
      }

      // ── the behavior engine: a base pose + timed OVERLAYS (events), eased ──
      const v = { rx: 0, ry: 0, rz: 0, y: 0 };          // eased current
      const goal = { rx: 0, ry: 0, rz: 0, y: 0 };       // where behaviors point it
      let overlay = null;                                // active event animation

      function fireEndTilt() {                           // (1) head-cock + eye-close
        if (overlay) return;
        const dir = Math.random() < .5 ? -1 : 1, s = P.etS;
        overlay = { until: performance.now() + 650 + s * 350, rz: dir * (8 + s * 12), rx: 2 + s * 3 };
        setEyes(false);
        setTimeout(() => { setEyes(true); }, 500 + s * 350);
      }
      function fireNod() {                               // (2) affirmation nod
        const s = P.anS, seq = [7 + s * 8, -2, 5 + s * 4, 0];
        seq.forEach((d, i) => setTimeout(() => cube.style.setProperty("--nod", d + "deg"), i * 130));
      }
      let attn = "you";                                  // (4) attention target
      function switchAttention(to) {
        attn = to || (attn === "you" ? "board" : "you");
        goal.ry = attn === "board" ? -22 : 0;
        goal.rx = attn === "board" ? 2 : 0;
      }

      // idle scheduler (3): every 2.4-5s pick ONE idle from the weighted set
      let idleTimer = null;
      function scheduleIdle() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => {
          if (RMS < .05) {
            const w = [["still", P.idStill], ["look", P.idLook], ["tilt", P.idTilt], ["blink", P.idBlink]];
            const total = w.reduce((a, [, x]) => a + x, 0) || 1;
            let r = Math.random() * total, pick = "still";
            for (const [k, x] of w) { r -= x; if (r <= 0) { pick = k; break; } }
            if (pick === "look") { goal.ry = (Math.random() * 2 - 1) * 18; setTimeout(() => switchAttention(attn), 1400); }
            if (pick === "tilt") { goal.rz = (Math.random() * 2 - 1) * 6; setTimeout(() => goal.rz = 0, 1200); }
            if (pick === "blink") { setEyes(false); setTimeout(() => setEyes(true), 260); }
          }
          scheduleIdle();
        }, 2400 + Math.random() * 2600);
      }
      scheduleIdle();

      // attention auto-switching (4) — rate slider = switches per ~10s
      (function attnLoop() {
        setTimeout(() => { if (Math.random() < P.atRate) switchAttention(); attnLoop(); },
          2500 + Math.random() * 3000);
      })();

      // ── the frame loop: ease toward goals; talk-motion rides live RMS ──
      let RMS = 0, lastRMS = 0, silentMs = 0, lastT = performance.now(), bt = 0;
      function frame(now) {
        const dt = now - lastT; lastT = now; bt += dt / 1000;
        // sentence-end detection: talking → ≥340ms silence
        if (RMS > .07) silentMs = 0; else silentMs += dt;
        if (lastRMS > .07 && RMS <= .07) silentMs = 1;
        if (silentMs > 0 && silentMs < dt + 1 && lastRMS <= .07) {} // noop
        if (silentMs > 340 && silentMs - dt <= 340 && !document.getElementById("take").paused) {
          if (Math.random() < P.etP) fireEndTilt();
        }
        lastRMS = RMS;
        // talk motion (5): only while speaking
        const talking = RMS > .06 ? Math.min(1, RMS * 3) : 0;
        const amt = P.tmAmt * talking;
        const sway = P.tmSway * amt * Math.sin(bt * 1.7) * 4;
        const bob = P.tmBob * amt * RMS * 10;
        const lean = P.tmLean * amt * 3;
        // ease current → goal (+ overlay events win)
        const o = overlay && performance.now() < overlay.until ? overlay : (overlay = null);
        const tx = (o ? o.rx : goal.rx + lean), tz = (o ? o.rz : goal.rz + sway);
        v.rx += (tx - v.rx) * .07; v.ry += (goal.ry - v.ry) * .06;
        v.rz += (tz - v.rz) * (o ? .12 : .07); v.y += ((-bob) - v.y) * .3;
        cube.style.setProperty("--rx", (-v.rx).toFixed(2) + "deg");
        cube.style.setProperty("--ry", v.ry.toFixed(2) + "deg");
        cube.style.setProperty("--rz", v.rz.toFixed(2) + "deg");
        cube.style.setProperty("--br", (Math.sin(bt * 2 * Math.PI / 4) * .7).toFixed(2) + "deg");
        scene.style.setProperty("--sy", v.y.toFixed(1) + "px");
        // jaw from RMS: viseme-ish mouth swap
        setMouth(RMS > .16 ? "AA" : RMS > .07 ? "B" : "neutral");
        requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);

      // ── voice picker + audio RMS ──
      const sel = document.getElementById("voice");
      Object.keys(TRAITS).sort().forEach(n => {
        const o = document.createElement("option"); o.value = n; o.textContent = n; sel.appendChild(o);
      });
      function load(name) {
        P = fromTraits(TRAITS[name]); syncSliders();
        document.getElementById("take").src = `/voices/take/${name}.wav`;
      }
      sel.onchange = () => load(sel.value);
      load(sel.value = Object.keys(TRAITS).sort()[0]);

      document.getElementById("f-end").onclick = fireEndTilt;
      document.getElementById("f-affirm").onclick = fireNod;
      document.getElementById("f-switch").onclick = () => switchAttention();

      let actx, analyser;
      document.getElementById("take").onplay = e => {
        if (!actx) {
          actx = new (window.AudioContext || window.webkitAudioContext)();
          analyser = actx.createAnalyser(); analyser.fftSize = 512;
          const src = actx.createMediaElementSource(e.target);
          src.connect(analyser); analyser.connect(actx.destination);
          const buf = new Uint8Array(analyser.fftSize);
          (function tick() {
            analyser.getByteTimeDomainData(buf);
            let s = 0;
            for (let i = 0; i < buf.length; i++) { const d = (buf[i] - 128) / 128; s += d * d; }
            RMS = e.target.paused ? 0 : Math.min(1, Math.sqrt(s / buf.length) * 4);
            document.querySelector("#meter i").style.width = (RMS * 100) + "%";
            requestAnimationFrame(tick);
          })();
        }
        actx.resume();
      };
    </script>
    """
  end
end
