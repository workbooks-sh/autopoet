// ── voice call bar: speech + mouth sync + push-to-talk ─────────────────────
document.getElementById("callend").onclick = () => setComm(null);
document.getElementById("callspeaker").onclick = () => {
  voiceSpeaker = !voiceSpeaker;
  const b = document.getElementById("callspeaker");
  b.classList.toggle("off", !voiceSpeaker);
  b.innerHTML = `<i data-lucide="${voiceSpeaker ? "volume-2" : "volume-x"}"></i>`;
  refreshIcons();
  if (voiceMode === "live") { if (live.gain) live.gain.gain.value = voiceSpeaker ? 1 : 0; }
  else if (!voiceSpeaker) authedPost("/speak/stop", "");
};

function say(text) {
  if (voiceSpeaker) authedPost("/speak", text);
  showCaption(text);
}
function showCaption(text) {
  const cap = document.getElementById("callcaption");
  cap.textContent = text;
  cap.classList.add("on");
}

// ══ the LIVE call (Gemini realtime): ws bridge, mic in, native audio out ═══
let voiceMode = "local";
const live = { ws: null, ctx: null, gain: null, playhead: 0, sources: [], amps: [],
               mic: null, micCtx: null, micOn: true, caption: "" };

// ── VoiceStage hooks: the SEAMLESS graph⇄call transition ────────────────────
// The cube that lives as the graph's self node is ADOPTED by the call: the
// world recedes, the same cube floats free on the same paper, and on hangup
// it glides back onto its node and the world returns. One avatar, two states.
function vsSelfSpot() {
  // the cube's stage-relative movement vars for the self node's footprint
  const n = worldData?.nodes?.find(n => n.id === "self");
  const stage = document.getElementById("stage");
  if (!n || n.x == null) return { sx: 0, sy: 0, sc: 96 / 132 };
  const t = d3.zoomTransform(svg.node());
  return { sx: t.applyX(n.x) - stage.clientWidth / 2,
           sy: t.applyY(n.y) - stage.clientHeight / 2,
           sc: (96 / 132) * t.k };
}
function vsHideWorld() {
  if (!nodeSel) return;
  nodeSel.filter(d => d.id !== "self").transition("vs").duration(420).attr("opacity", 0)
    .on("end", function () { d3.select(this).style("pointer-events", "none"); });
  if (linkSel) linkSel.transition("vs").duration(420).attr("opacity", 0);
  if (window.vsBadgeLayer) window.vsBadgeLayer.transition("vs").duration(420).attr("opacity", 0);
  if (window.vsHullLayer) window.vsHullLayer.transition("vs").duration(420).attr("opacity", 0)
    .style("pointer-events", "none");
  svg.on(".zoom", null);                                // freeze pan/zoom during the call
}
function vsShowWorld() {
  if (!nodeSel) return;
  nodeSel.transition("vs").duration(520).attr("opacity", 1).style("pointer-events", "all");
  if (linkSel) linkSel.transition("vs").duration(520).attr("opacity", 1);
  if (window.vsBadgeLayer) window.vsBadgeLayer.transition("vs").duration(520).attr("opacity", 1);
  if (window.vsHullLayer) window.vsHullLayer.transition("vs").duration(520).attr("opacity", 1)
    .style("pointer-events", "all");
  svg.call(zoomB);                                      // pan/zoom back on
}

async function startVoice() {
  voiceMode = (await (await fetch("/voice/mode")).text()).trim();
  if (voiceMode === "stage") {
    // local speech-to-speech: the SAME self-node cube goes free-floating —
    // Silero VAD + local STT + Groq brain + Kokoro voice. setComm already ran
    // zoomTo("self"); settleMs lets the camera finish before the release.
    await ensureSelfCube();
    VoiceStage.enter({ token: TOKEN, stage: document.getElementById("stage"),
                       callbar: document.getElementById("callbar"),
                       callin: document.getElementById("callin"),
                       adopt: { scene: selfCube, cube: selfCubeInner, prefix: "ap-" },
                       selfSpot: vsSelfSpot, hideWorld: vsHideWorld, showWorld: vsShowWorld,
                       resync: syncSelfCube,
                       settleMs: 620 });
    return;
  }
  startVoicePoll();
  if (voiceMode !== "live") { say("voice link up. I'm here."); return; }
  const ws = new WebSocket(`ws://127.0.0.1:${location.port}/voice/live?token=${TOKEN}`);
  live.ws = ws;
  live.ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 });
  live.gain = live.ctx.createGain();
  live.gain.connect(live.ctx.destination);
  live.playhead = 0; live.caption = "";
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.type === "ready") { startMic(); showCaption("voice link up — say something"); }
    else if (m.type === "audio") queueLiveAudio(m.data);
    else if (m.type === "caption") {
      live.caption += m.text;
      showCaption(live.caption);
      groundFromCaption(m.text);   // light up what it's talking about
    }
    else if (m.type === "turn_complete") { live.caption = ""; setTimeout(() =>
      document.getElementById("callcaption").classList.remove("on"), 1600); }
    else if (m.type === "interrupted") flushLiveAudio();
    else if (m.type === "tool") showCaption("⌕ " + m.cmd);   // it's looking something up
  };
  ws.onclose = () => { if (commState === "voice" && voiceMode === "live") showCaption("voice link dropped"); };
}
function stopVoice() {
  if (voiceMode === "stage") { VoiceStage.exit(); return; }
  stopVoicePoll();
  clearGrounding();
  if (voiceMode === "live") {
    try { live.ws?.close(); } catch (_) {}
    flushLiveAudio();
    try { live.ctx?.close(); } catch (_) {}
    live.mic?.getTracks().forEach(t => t.stop());
    try { live.micCtx?.close(); } catch (_) {}
    live.ws = live.ctx = live.mic = live.micCtx = null;
    document.getElementById("callmic").style.display = "none";
  } else {
    authedPost("/speak/stop", "");
  }
}

// audio OUT: 24kHz pcm16 chunks → scheduled buffers + amplitude timeline
function queueLiveAudio(b64) {
  const raw = atob(b64);
  const n = raw.length / 2;
  const f32 = new Float32Array(n);
  const rms = [];
  const win = Math.round(24000 * 0.05);
  let sum = 0;
  for (let i = 0; i < n; i++) {
    let v = raw.charCodeAt(2 * i) | (raw.charCodeAt(2 * i + 1) << 8);
    if (v >= 0x8000) v -= 0x10000;
    const s = v / 32768;
    f32[i] = s; sum += s * s;
    if ((i + 1) % win === 0) { rms.push(Math.sqrt(sum / win)); sum = 0; }
  }
  const buf = live.ctx.createBuffer(1, n, 24000);
  buf.getChannelData(0).set(f32);
  const src = live.ctx.createBufferSource();
  src.buffer = buf; src.connect(live.gain);
  const t0 = Math.max(live.ctx.currentTime + 0.06, live.playhead);
  src.start(t0);
  live.playhead = t0 + buf.duration;
  live.sources.push(src);
  live.amps.push({ t0, dur: buf.duration, rms });
  src.onended = () => { live.sources = live.sources.filter(s => s !== src); };
}
function flushLiveAudio() {
  live.sources.forEach(s => { try { s.stop(); } catch (_) {} });
  live.sources = []; live.amps = [];
  if (live.ctx) live.playhead = live.ctx.currentTime;
}
function liveAmpNow() {
  if (!live.ctx) return 0;
  const t = live.ctx.currentTime;
  const seg = live.amps.find(a => t >= a.t0 && t < a.t0 + a.dur);
  if (!seg) return 0;
  // normalize against the segment's own peak so quiet voices still move the mouth
  const peak = Math.max(0.08, ...seg.rms);
  return (seg.rms[Math.floor((t - seg.t0) / 0.05)] ?? 0) / peak;
}

// audio IN: mic → downsample to 16kHz pcm16 → b64 chunks up the socket
async function startMic() {
  try {
    live.mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
  } catch (err) {
    showCaption("mic unavailable (" + err.name + ") — type below to talk");
    return;
  }
  document.getElementById("callmic").style.display = "flex";
  live.micCtx = new (window.AudioContext || window.webkitAudioContext)();
  const srcNode = live.micCtx.createMediaStreamSource(live.mic);
  const proc = live.micCtx.createScriptProcessor(4096, 1, 1);
  const ratio = live.micCtx.sampleRate / 16000;
  let speechFrames = 0;
  proc.onaudioprocess = e => {
    if (!live.micOn || !live.ws || live.ws.readyState !== 1) return;
    const inp = e.inputBuffer.getChannelData(0);
    // the human speaking clears the grounding highlights (folders stay open)
    if (grounded.size) {
      let s = 0;
      for (let i = 0; i < inp.length; i += 16) s += inp[i] * inp[i];
      speechFrames = Math.sqrt(s / (inp.length / 16)) > 0.03 ? speechFrames + 1 : 0;
      if (speechFrames >= 3) { clearGrounding(); speechFrames = 0; }
    }
    const out = new Int16Array(Math.floor(inp.length / ratio));
    for (let i = 0; i < out.length; i++) {
      // average the group — cheap anti-alias for the downsample
      const a = Math.floor(i * ratio), b = Math.floor((i + 1) * ratio);
      let s = 0;
      for (let j = a; j < b; j++) s += inp[j];
      out[i] = Math.max(-32768, Math.min(32767, (s / (b - a)) * 32768));
    }
    let bin = "";
    const bytes = new Uint8Array(out.buffer);
    for (let i = 0; i < bytes.length; i += 8192)
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    live.ws.send(JSON.stringify({ type: "audio", data: btoa(bin) }));
  };
  srcNode.connect(proc);
  proc.connect(live.micCtx.destination);   // ScriptProcessor needs a sink to run
}
document.getElementById("callmic").onclick = () => {
  live.micOn = !live.micOn;
  const b = document.getElementById("callmic");
  b.classList.toggle("off", !live.micOn);
  b.innerHTML = `<i data-lucide="${live.micOn ? "mic" : "mic-off"}"></i>`;
  refreshIcons();
};

