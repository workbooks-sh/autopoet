// ── REAL lip sync: mouth openness follows the audio's amplitude envelope ────
// The server parses the rendered AIFF into RMS-per-50ms; we sample it at the
// playhead. Pauses sit flat; syllables open the mouth; silence closes it.
let voicePoll = null, mouthTimer = null, voiceSync = null, syncAt = 0;

// the classic viseme chart (Preston Blair / Rhubarb set) — SEPARATE static
// shapes, each a distinct phonetic mouth, swapped whole. Drawn in the face's
// own 80×80 line-art style around the mouth anchor (42, 47.5).
const VISEMES = {
  X: null,   // rest → the real neutral mood line
  A: `<path d="M35.5 47.1 q6.5 2.2 13 0 q-6.5 2.4 -13 0 Z" fill="black"/>`,                 // M B P — pressed bean
  B: `<rect x="35.8" y="46.1" width="12.4" height="2.7" rx="1.35" fill="black"/>`,          // EE S T — teeth, spread
  C: `<rect x="36.6" y="45.3" width="10.8" height="4.9" rx="2.4" fill="black"/>`,           // EH — half open
  D: `<path d="M35.2 45.3 h13.6 q0 7 -6.8 7 q-6.8 0 -6.8 -7 Z" fill="black"/>`,             // AA — wide open
  E: `<circle cx="42" cy="47.8" r="3.5" fill="black"/>`,                                    // AO ER — round open
  F: `<circle cx="42" cy="47.6" r="1.9" fill="black"/>`,                                    // OO W — pucker
  G: `<path d="M35.9 46.4 h12.2 v1.5 q-6.1 2.3 -12.2 0 Z" fill="black"/>`                   // F V — lip bite
};
let curViseme = null;
function setViseme(v) {
  if (v === curViseme) return;   // swap only when the shape actually changes
  curViseme = v;
  if (v === "X") return setMouth("neutral");
  const g = document.getElementById("ap-mouth");
  if (g) g.innerHTML = VISEMES[v];
}
// which viseme: the letter under the playhead picks the shape class
// (say's rate is fixed, so text position ≈ playhead fraction); amplitude
// gates rest/openness within the class
function visemeAt(text, frac, amp) {
  if (amp < 0.1 || !text) return "X";
  const i = Math.max(0, Math.min(text.length - 1, Math.round(frac * text.length)));
  const near = (text.slice(i, i + 3).match(/[a-z]/i) || [text[i]])[0].toLowerCase();
  if ("mbp".includes(near)) return "A";
  if ("fv".includes(near)) return "G";
  if ("ouw".includes(near)) return amp > 0.55 ? "E" : "F";
  if (near === "a") return amp > 0.6 ? "D" : "C";
  if ("eiy".includes(near)) return "B";
  return amp > 0.5 ? "C" : "B";
}

function startVoicePoll() {
  if (voicePoll) return;
  voicePoll = setInterval(async () => {
    try {
      voiceSync = await (await fetch("/voice/sync.json")).json();
      syncAt = performance.now();
      if (voiceSync.status !== "speaking")
        document.getElementById("callcaption").classList.remove("on");
    } catch (_) {}
  }, 250);
  mouthTimer = setInterval(() => {
    if (voiceMode === "live") {
      // live call: amplitude from the playing PCM; shape class from the caption tail
      const amp = liveAmpNow();
      setViseme(amp < 0.1 ? "X" : visemeAt(live.caption || "aeo", 0.92, amp));
      return;
    }
    if (!voiceSync || voiceSync.status !== "speaking" || !voiceSync.envelope.length) {
      setViseme("X");
      return;
    }
    const playhead = voiceSync.elapsed_ms + (performance.now() - syncAt);
    const duration = voiceSync.envelope.length * voiceSync.window_ms;
    const amp = voiceSync.envelope[Math.floor(playhead / voiceSync.window_ms)] ?? 0;
    setViseme(visemeAt(voiceSync.text, playhead / duration, amp));
  }, 50);
}
function stopVoicePoll() {
  clearInterval(voicePoll); voicePoll = null;
  clearInterval(mouthTimer); mouthTimer = null;
  voiceSync = null; curViseme = null;
  setMouth("neutral");
  document.getElementById("callcaption").classList.remove("on");
}

// ── voice grounding: highlight what the autopoet mentions; clear when the
// human starts talking (folders it opened stay open) ────────────────────────
const grounded = new Set();
const escRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const nameRe = name => new RegExp("\\b" + escRe(name).replace(/[_-]/g, "[ _-]?") + "\\b");

function groundFromCaption(chunk) {
  const t = chunk.toLowerCase();
  worldData.nodes.forEach(n => {
    const name = (n.label || "").toLowerCase();
    if (name.length >= 4 && !grounded.has(n.id) && nameRe(name).test(t)) groundNode(n.id);
  });
  document.querySelectorAll("#tree .row[data-kind]").forEach(el => {
    const base = el.dataset.path.split("/").pop().replace(/\.(md|sketch\.svg|svg)$/i, "").toLowerCase();
    if (base.length >= 4 && !grounded.has("t:" + el.dataset.path) && nameRe(base).test(t))
      groundTree(el.dataset.path);
  });
}
function groundNode(id) {
  grounded.add(id);
  if (!nodeSel) return;
  nodeSel.filter(d => d.id === id).each(function (d) {
    d3.select(this).append("circle").attr("class", "ground-ring").attr("r", radius(d) + 9);
  });
}
async function groundTree(path) {
  grounded.add("t:" + path);
  // open the enclosing folders — these deliberately STAY open after clearing
  const parts = path.split("/");
  let prefix = "", changed = false;
  for (let i = 0; i < parts.length - 1; i++) {
    prefix = prefix ? prefix + "/" + parts[i] : parts[i];
    if (closedFolders.has(prefix)) { closedFolders.delete(prefix); changed = true; }
  }
  if (changed) { persistFolders(); await loadTree(); }
  document.querySelector(`#tree .row[data-path="${CSS.escape(path)}"]`)?.classList.add("grounded");
}
function clearGrounding() {
  grounded.clear();
  g.selectAll(".ground-ring").remove();
  document.querySelectorAll("#tree .row.grounded").forEach(el => el.classList.remove("grounded"));
}

// typed push-to-talk: in a live call it's a text turn on the socket; in local
// mode it's planner → say
let voiceBusy = false;
document.getElementById("callin").addEventListener("keydown", async e => {
  if (e.key !== "Enter" || voiceBusy) return;
  const inp = e.target, msg = inp.value.trim();
  if (!msg) return;
  inp.value = "";
  if (voiceMode === "stage") { VoiceStage.ask(msg); return; }
  if (voiceMode === "live" && live.ws?.readyState === 1) {
    live.caption = "";
    clearGrounding();   // typed input counts as the human talking
    live.ws.send(JSON.stringify({ type: "text", text: msg }));
    return;
  }
  inp.placeholder = "…thinking";
  voiceBusy = true;
  try {
    const res = await authedPost("/chat/send?id=voice", msg);
    const reply = await res.text();
    say(res.ok ? reply : "I hit an error answering that.");
  } catch (_) {
    say("connection trouble.");
  }
  voiceBusy = false;
  inp.placeholder = "say something…";
  inp.focus();
});

loadTree();
draw();
try { window.VoiceStage && VoiceStage.preload(); } catch (e) {}   // voice engine probe — never fatal at boot
refreshIcons();
updateDirtyUI();   // hot exit: restored buffers resurface the save prompt + tree dots

