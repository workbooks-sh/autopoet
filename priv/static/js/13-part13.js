// ══ COMM: chat & voice (one at a time; chat shares column 2 with files) ═══
let commState = null;   // null | "chat" | "voice"
let currentChat = localStorage.getItem("ap-chat") || null;
let voiceSpeaker = true;

function setComm(state) {
  if (state === commState) state = null;   // clicking the active one toggles off
  const wasVoice = commState === "voice";
  commState = state;
  document.getElementById("comm-chat").classList.toggle("sel", state === "chat");
  document.getElementById("comm-voice").classList.toggle("sel", state === "voice");
  const app = document.getElementById("app");
  app.classList.toggle("chatting", state === "chat");
  if (state === "chat") {
    // the chat and a file can't share the slot — collapse any open file (buffers persist)
    app.classList.remove("editing", "sketching");
    open = { path: null, kind: null };
    loadTree();
    openChat();
  }
  document.getElementById("callbar").classList.toggle("on", state === "voice");
  if (state === "voice") {
    zoomTo("self", false);                       // the call focuses on the face
    startVoice();
    setTimeout(() => document.getElementById("callin").focus(), 400);
  } else if (wasVoice) {
    stopVoice();
  }
  relayout();
}
document.getElementById("comm-chat").onclick = () => setComm("chat");
document.getElementById("comm-voice").onclick = () => setComm("voice");
const authedPost = (url, body) => fetch(url, { method: "POST", body, ...authed });

// ── chat panel ─────────────────────────────────────────────────────────────
async function openChat() {
  if (!currentChat) {
    currentChat = (await (await authedPost("/chat/new", "")).text()).trim();
    localStorage.setItem("ap-chat", currentChat);
  }
  document.getElementById("chatpanel").classList.remove("sessions");
  const t = await (await fetch("/chat/transcript?id=" + encodeURIComponent(currentChat))).text();
  renderChat(t);
  setTimeout(() => document.getElementById("chatin").focus(), 150);
}
function renderChat(transcript) {
  const log = document.getElementById("chatlog");
  log.innerHTML = "";
  transcript.split("\n").forEach(line => {
    if (line.startsWith("[user] ")) addMsg("user", line.slice(7));
    else if (line.startsWith("[autopoet] ")) addMsg("ap", line.slice(11));
  });
  log.scrollTop = log.scrollHeight;
}
function addMsg(who, text) {
  const log = document.getElementById("chatlog");
  const d = document.createElement("div");
  d.className = "m " + who;
  // inline components: ``` blocks → mono cards, [[refs]] → highlighted
  const parts = text.replace(/ ⏎ /g, "\n").split(/```/);
  parts.forEach((p, i) => {
    if (i % 2 === 1) {
      const b = document.createElement("span");
      b.className = "blk"; b.textContent = p.trim();
      d.appendChild(b);
    } else {
      p.split(/(\[\[[^\]]+\]\])/).forEach(seg => {
        const m = seg.match(/^\[\[([^\]]+)\]\]$/);
        if (m) {
          const r = document.createElement("span");
          r.className = "ref"; r.textContent = m[1];
          r.style.cursor = "pointer";
          r.onclick = () => { const n = worldData.nodes.find(n => n.label === m[1]); if (n) zoomTo(n.id); };
          d.appendChild(r);
        } else if (seg) d.appendChild(document.createTextNode(seg));
      });
    }
  });
  log.appendChild(d);
  log.scrollTop = log.scrollHeight;
  return d;
}
async function sendChat() {
  const inp = document.getElementById("chatin");
  const msg = inp.value.trim();
  if (!msg || !currentChat) return;
  inp.value = ""; inp.style.height = "auto";
  addMsg("user", msg);
  const send = document.getElementById("chatsend");
  send.disabled = true;
  const typing = document.createElement("div");
  typing.className = "typing"; typing.textContent = "…thinking";
  document.getElementById("chatlog").appendChild(typing);
  try {
    const res = await authedPost("/chat/send?id=" + encodeURIComponent(currentChat), msg);
    const reply = await res.text();
    typing.remove();
    addMsg("ap", res.ok ? reply : "(" + reply.trim() + ")");
  } catch (err) {
    typing.remove();
    addMsg("ap", "(connection failed: " + err.message + ")");
  }
  send.disabled = false;
  inp.focus();
}
