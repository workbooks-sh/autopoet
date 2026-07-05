defmodule Autopoet.VoicePlayground do
  @moduledoc """
  The pose-engine playground (`GET /voices/playground`) — pick a voice, the
  cube carries itself per that voice's motion traits (data/voices/traits),
  and while its take plays, live audio RMS drives the jaw and modulates
  arousal. The pure function at the heart — pose(traits, valence, arousal,
  rms) — is the exact mapping the voice stage adopts in phase 2; this page
  exists to FEEL the vectors before wiring them into the performer.
  """

  def html do
    traits =
      for name <- Autopoet.VoicePersonas.names() ++ Autopoet.VoiceRoster.pinned(),
          t = Autopoet.VoiceRoster.traits(name),
          t != nil,
          into: %{} do
        take = Path.join(Autopoet.VoiceRoster.takes_dir(), name <> ".wav")
        {name, Map.put(t, "take", File.exists?(take))}
      end

    ~s"""
    <!doctype html><meta charset="utf-8"><title>pose playground</title>
    <style>
      body{font:14px/1.6 ui-monospace,Menlo,monospace;background:#f7f6f1;color:#16161a;margin:0;
        display:grid;grid-template-columns:300px 1fr;height:100vh}
      #side{padding:26px 20px;border-right:1px solid #e2e6ec;overflow-y:auto;background:#fff}
      h1{font-size:16px;margin:0 0 4px}.sub{color:#6a6f68;font-size:11.5px;margin-bottom:16px}
      select{appearance:none;-webkit-appearance:none;width:100%;font:600 12.5px ui-monospace,monospace;
        padding:8px 12px;border:1.4px solid #d6dbe2;border-radius:10px;background:#fff;cursor:pointer}
      .lbl{font:600 9.5px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.07em;color:#8a8f88;margin:14px 0 4px}
      .tr{display:flex;align-items:center;gap:8px;font:10.5px ui-monospace,monospace;color:#6a6f68;margin:3px 0}
      .tr span{width:86px;flex:none}
      .tr input{flex:1;accent-color:#16161a}
      .move{font:11px/1.5 ui-monospace,monospace;color:#4a4f48;background:#f6f8fa;border-radius:9px;padding:8px 11px;margin-top:10px}
      audio{width:100%;margin-top:14px}
      #meter{height:6px;background:#eef0f2;border-radius:3px;margin-top:8px;overflow:hidden}
      #meter i{display:block;height:100%;width:0;background:#16161a;transition:width .06s linear}
      #stage{position:relative;overflow:hidden;
        background-image:linear-gradient(#eef1f5 1px,transparent 1px),linear-gradient(90deg,#eef1f5 1px,transparent 1px);
        background-size:24px 24px}
      #scene{position:absolute;left:50%;top:50%;width:132px;height:132px;margin:-66px 0 0 -66px;
        transform:translate(var(--sx,0px),var(--sy,0px))}
      #cube{position:absolute;inset:0;transform-style:preserve-3d;
        transform:perspective(700px) rotateX(var(--rx,0deg)) rotateY(var(--ry,0deg)) rotateZ(var(--rz,0deg)) rotateX(var(--br,0deg)) scale(var(--sc,1))}
      .layer{position:absolute;inset:0;border-radius:30px}
      #face{position:absolute;inset:0;display:grid;place-items:center}
      #face svg{width:100%;height:100%}
    </style>
    <div id="side">
      <h1>pose playground</h1>
      <p class="sub">the cube carries itself per the voice's traits; play the take and the audio energy drives it live.</p>
      <div class="lbl">voice</div>
      <select id="voice"></select>
      <div class="lbl">traits (live — drag to feel)</div>
      <div id="sliders"></div>
      <div class="lbl">emotion (manual for now — phase 2 reads the text)</div>
      <div class="tr"><span>valence</span><input type="range" id="valence" min="-1" max="1" step="0.05" value="0.3"></div>
      <div class="tr"><span>arousal</span><input type="range" id="arousal" min="0" max="1" step="0.05" value="0.4"></div>
      <div class="move" id="move"></div>
      <audio id="take" controls preload="none"></audio>
      <div id="meter"><i></i></div>
    </div>
    <div id="stage"><div id="scene"><div id="cube"></div></div></div>
    <script>
      const TRAITS = #{Jason.encode!(traits)};
      const KEYS = ["energy","expanse","warmth","steadiness","dominance","playfulness"];
      let T = {}, V = 0.3, A = 0.4, RMS = 0;

      // ── the cube (voice-stage buildCube pattern: stacked toon layers + face) ──
      const cube = document.getElementById("cube");
      for (let z = 60; z >= -66; z -= 6) {
        const k = Math.pow((66 - z) / 132, 0.75);
        const d = document.createElement("div");
        d.className = "layer";
        d.style.background = `rgb(${255 - k * 48},${255 - k * 48},${255 - k * 55})`;
        d.style.transform = `translateZ(${z}px)`;
        cube.appendChild(d);
      }
      const face = document.createElement("div");
      face.id = "face";
      face.style.transform = "translateZ(66px)";
      face.innerHTML = `<svg viewBox="0 0 40 40">
        <g id="eyes"><circle cx="14" cy="17" r="2.6" fill="#16161a"/><circle cx="26" cy="17" r="2.6" fill="#16161a"/></g>
        <path id="mouth" d="M14 26 q6 3 12 0" stroke="#16161a" stroke-width="2" fill="none" stroke-linecap="round"/>
      </svg>`;
      cube.appendChild(face);
      const scene = document.getElementById("scene");
      const eyes = face.querySelector("#eyes"), mouth = face.querySelector("#mouth");

      // ── THE POSE FUNCTION — traits × emotion × live energy → the levers ──
      // (this exact mapping graduates to the voice stage in phase 2)
      function pose(t, v, a, rms, time) {
        const aLive = Math.min(1, a * 0.6 + rms * 0.9);            // energy excites arousal
        const wob = (f, p) => Math.sin(time * f + p);
        const jit = 1 - (t.steadiness ?? 0.5);
        return {
          driftX: (t.energy ?? .5) * (14 + aLive * 30) * wob(0.55 + jit * 0.5, 0),
          driftY: (t.energy ?? .5) * (8 + aLive * 18) * wob(0.4 + jit * 0.4, 2),
          rx: (t.dominance ?? .5) * -3                              // chin up when commanding
              + (v < 0 ? (-v) * (1 - aLive) * 9 : 0)                // head DOWN when sad+quiet
              + wob(0.9, 1) * jit * 1.5,
          rz: (t.playfulness ?? .5) * aLive * wob(1.3, 3) * 5,
          ry: wob(0.3, 4) * 4 * (t.energy ?? .5),
          brAmp: 0.5 + aLive * 1.6,
          brRate: 2 * Math.PI / (5.5 - ((t.energy ?? .5) + aLive) * 1.6),
          eyesUp: v < 0 ? (-v) * 2.2 : 0,                           // eyes lift when head drops
          smile: Math.max(-1, Math.min(1, (t.warmth ?? .5) * 0.8 + v * 0.9 - 0.35)),
          jaw: rms,
          bounceP: (t.expanse ?? .5) * aLive * 0.02                 // gesture impulses
        };
      }

      let bounce = 0;
      function frame(now) {
        const time = now / 1000;
        const p = pose(T, V, A, RMS, time);
        if (Math.random() < p.bounceP) bounce = 1;
        bounce *= 0.9;
        scene.style.setProperty("--sx", p.driftX.toFixed(1) + "px");
        scene.style.setProperty("--sy", (p.driftY - bounce * 14).toFixed(1) + "px");
        cube.style.setProperty("--rx", p.rx.toFixed(2) + "deg");
        cube.style.setProperty("--ry", p.ry.toFixed(2) + "deg");
        cube.style.setProperty("--rz", p.rz.toFixed(2) + "deg");
        cube.style.setProperty("--br", (Math.sin(time * p.brRate) * p.brAmp).toFixed(2) + "deg");
        cube.style.setProperty("--sc", (1 + bounce * 0.05).toFixed(3));
        eyes.setAttribute("transform", `translate(0 ${(-p.eyesUp).toFixed(1)})`);
        const open = 1 + p.jaw * 7;
        const curve = 3 * p.smile - p.jaw * 1.5;
        mouth.setAttribute("d", `M14 ${26 + p.jaw * 2} q6 ${curve + open - 1} 12 0`);
        requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);

      // ── voice picker + sliders ──
      const sel = document.getElementById("voice");
      Object.keys(TRAITS).sort().forEach(n => {
        const o = document.createElement("option"); o.value = n; o.textContent = n; sel.appendChild(o);
      });
      function load(name) {
        T = { ...TRAITS[name] };
        document.getElementById("move").textContent = T.movement || "";
        document.getElementById("sliders").innerHTML = KEYS.map(k => `
          <div class="tr"><span>${k}</span><input type="range" min="0" max="1" step="0.05" value="${T[k] ?? 0.5}" data-k="${k}"></div>`).join("");
        document.querySelectorAll("#sliders input").forEach(i => i.oninput = () => T[i.dataset.k] = +i.value);
        const audio = document.getElementById("take");
        audio.src = T.take ? `/voices/take/${name}.wav` : "";
        wireAudio(audio);
      }
      sel.onchange = () => load(sel.value);
      document.getElementById("valence").oninput = e => V = +e.target.value;
      document.getElementById("arousal").oninput = e => A = +e.target.value;

      // ── live RMS from the playing take ──
      let actx, analyser, srcNode, wired;
      function wireAudio(audio) {
        RMS = 0;
        if (wired === audio) return;
        audio.onplay = () => {
          if (!actx) {
            actx = new (window.AudioContext || window.webkitAudioContext)();
            analyser = actx.createAnalyser(); analyser.fftSize = 512;
            srcNode = actx.createMediaElementSource(audio);
            srcNode.connect(analyser); analyser.connect(actx.destination);
            const buf = new Uint8Array(analyser.fftSize);
            (function tick() {
              analyser.getByteTimeDomainData(buf);
              let s = 0;
              for (let i = 0; i < buf.length; i++) { const d = (buf[i] - 128) / 128; s += d * d; }
              RMS = audio.paused ? 0 : Math.min(1, Math.sqrt(s / buf.length) * 4);
              document.querySelector("#meter i").style.width = (RMS * 100) + "%";
              requestAnimationFrame(tick);
            })();
          }
          actx.resume();
        };
        wired = audio;
      }
      load(sel.value = Object.keys(TRAITS).sort()[0]);
    </script>
    """
  end
end
