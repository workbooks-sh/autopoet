// ── the composer (studio port): pickers, slash commands, emoji, live send ──
const chatin = document.getElementById("chatin");
let pickerRows = [], pickerType = null, pickerActive = 0;

// slash commands are REAL actions on the running system
const SLASH = [
  { name: "cycle", icon: "heart-pulse", hint: "run a heartbeat now",
    run: async () => { await authedPost("/cycle", ""); addMsg("ap", "cycle triggered — watch the console."); } },
  { name: "research", icon: "globe", hint: "research <topic> — dispatch the limb",
    run: async arg => {
      if (!arg) return addMsg("ap", "give me a topic: /research <topic>");
      await authedPost("/research", arg);
      addMsg("ap", "research limb dispatched: " + arg);
    } },
  { name: "status", icon: "activity", hint: "runtime status",
    run: async () => addMsg("ap", "```\n" + (await (await fetch("/status")).text()).trim() + "\n```") },
  { name: "proposals", icon: "bell", hint: "open notifications",
    run: () => { document.getElementById("cb-bell").click(); } }
];
const MENTION_KINDS = { limb: "#e07a5f", doc: "#4a90d9", guide: "#8e7cc3" };
const mentionCandidates = () =>
  worldData.nodes.filter(n => MENTION_KINDS[n.type])
    .map(n => ({ name: n.label, kind: n.type, id: n.id }));

function updatePicker() {
  const v = chatin.value;
  const pick = document.getElementById("picker");
  const cmd = v.match(/^\/(\w*)$/);
  const men = v.match(/(?:^|\s)@([\w-]*)$/);
  if (cmd) {
    pickerType = "command";
    pickerRows = SLASH.filter(c => c.name.startsWith(cmd[1].toLowerCase()));
  } else if (men) {
    pickerType = "mention";
    pickerRows = mentionCandidates().filter(r => r.name.toLowerCase().startsWith(men[1].toLowerCase())).slice(0, 10);
  } else pickerRows = [];
  pickerActive = Math.min(pickerActive, Math.max(0, pickerRows.length - 1));
  pick.classList.toggle("on", pickerRows.length > 0);
  if (!pickerRows.length) return;
  document.getElementById("pickerhead").innerHTML = pickerType === "mention"
    ? `<i data-lucide="at-sign"></i> mention a page or limb`
    : `<i data-lucide="terminal"></i> run a command`;
  document.getElementById("pickerrows").innerHTML = pickerRows.map((r, i) => {
    const c = pickerType === "mention" ? MENTION_KINDS[r.kind] : "#67707c";
    const icon = pickerType === "mention" ? (r.kind === "limb" ? "cpu" : "file-text") : r.icon;
    return `<button class="prow ${i === pickerActive ? "act" : ""}" data-i="${i}">
      <span class="pic" style="color:${c};background:${c}22"><i data-lucide="${icon}"></i></span>
      <span><span class="sig">${pickerType === "command" ? "/" : "@"}</span>${esc(r.name)}</span>
      ${r.hint ? `<span class="phint">${esc(r.hint)}</span>` : ""}
      ${pickerType === "mention" ? `<span class="tag" style="color:${c};background:${c}22">${r.kind}</span>` : ""}
    </button>`;
  }).join("");
  document.querySelectorAll("#picker .prow").forEach(el => {
    el.onmouseenter = () => { pickerActive = +el.dataset.i; updatePicker(); };
    el.onclick = () => choosePick(pickerRows[+el.dataset.i]);
  });
  refreshIcons();
}
function choosePick(row) {
  if (pickerType === "mention")
    chatin.value = chatin.value.replace(/(^|\s)@[\w-]*$/, (m, pre) => `${pre}@${row.name} `);
  else chatin.value = `/${row.name} `;
  pickerActive = 0;
  updatePicker(); syncSend();
  chatin.focus();
}
const EMOJI = ["👍","👎","🎉","👀","✅","❤️","🔥","😄","😂","🙏","👏","💯",
  "🚀","⭐","💡","🤔","😅","😎","🙌","👌","💪","🎯","⚡","✨","🐛","🛠️","📌","🚨","😬","🥳"];
document.getElementById("emojipop").innerHTML = EMOJI.map(e => `<button>${e}</button>`).join("");
document.querySelectorAll("#emojipop button").forEach(b =>
  b.onclick = () => {
    chatin.value += b.textContent;
    document.getElementById("emojipop").classList.remove("on");
    syncSend(); chatin.focus();
  });
document.getElementById("tb-emoji").onclick = () =>
  document.getElementById("emojipop").classList.toggle("on");
document.getElementById("tb-at").onclick = () => {
  chatin.value += (chatin.value && !chatin.value.endsWith(" ") ? " " : "") + "@";
  updatePicker(); chatin.focus();
};
document.getElementById("tb-slash").onclick = () => {
  if (!chatin.value.trim()) chatin.value = "/";
  updatePicker(); chatin.focus();
};

function syncSend() {
  document.getElementById("chatsend").classList.toggle("ready", !!chatin.value.trim());
}
async function submitComposer() {
  const v = chatin.value.trim();
  const m = v.match(/^\/(\w+)\s*(.*)$/);
  const cmd = m && SLASH.find(c => c.name === m[1]);
  if (cmd) {
    chatin.value = ""; syncSend(); updatePicker();
    addMsg("user", v);
    return cmd.run(m[2].trim());
  }
  sendChat();
}
document.getElementById("chatsend").onclick = submitComposer;
chatin.addEventListener("keydown", e => {
  if (pickerRows.length) {
    if (e.key === "ArrowDown") { e.preventDefault(); pickerActive = (pickerActive + 1) % pickerRows.length; return updatePicker(); }
    if (e.key === "ArrowUp") { e.preventDefault(); pickerActive = (pickerActive - 1 + pickerRows.length) % pickerRows.length; return updatePicker(); }
    if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); return choosePick(pickerRows[pickerActive]); }
    if (e.key === "Escape") { chatin.value = chatin.value.replace(/(^|\s)@[\w-]*$/, "$1").replace(/^\/\w*$/, ""); return updatePicker(); }
  }
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submitComposer(); }
});
chatin.addEventListener("input", e => {
  e.target.style.height = "auto";
  e.target.style.height = Math.min(e.target.scrollHeight, 190) + "px";
  updatePicker(); syncSend();
});
document.getElementById("chatclose").onclick = () => setComm(null);
document.getElementById("chatnew").onclick = async () => {
  currentChat = (await (await authedPost("/chat/new", "")).text()).trim();
  localStorage.setItem("ap-chat", currentChat);
  document.getElementById("chatpanel").classList.remove("sessions");
  renderChat("");
  document.getElementById("chatin").focus();
};
document.getElementById("chathistory").onclick = async () => {
  const panel = document.getElementById("chatpanel");
  if (panel.classList.toggle("sessions")) {
    const sess = await (await fetch("/chat/sessions.json")).json();
    document.getElementById("chatsessions").innerHTML = sess.length
      ? sess.map(s => `<div class="sess" data-id="${esc(s.id)}">${esc(s.preview || "(empty)")}<div class="id">${esc(s.id)}</div></div>`).join("")
      : `<div class="sess">no sessions yet</div>`;
    document.querySelectorAll("#chatsessions .sess[data-id]").forEach(el =>
      el.onclick = () => {
        currentChat = el.dataset.id;
        localStorage.setItem("ap-chat", currentChat);
        openChat();
      });
  }
};

