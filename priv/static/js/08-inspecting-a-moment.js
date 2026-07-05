// ── inspecting a moment ──────────────────────────────────────────────────────
// Clicking a row NEVER changes anything — it opens the inspect strip: what
// happened here in plain words, which files it touched, and one clearly-labeled
// action ("rewind notes to here") for actual time travel.
function histHuman(n) {
  const d = n.desc || "";
  let m;
  if (!d && n.at) return "now — this is where your next change will land";
  if ((m = d.match(/^vault: wrote (.+)$/))) return `you edited ${m[1]}`;
  if ((m = d.match(/^vault: created (.+)$/))) return `you created ${m[1]}`;
  if ((m = d.match(/^vault: renamed (.+)$/))) return `you renamed ${m[1]}`;
  if ((m = d.match(/^vault: deleted (.+)$/))) return `you deleted ${m[1]}`;
  if ((m = d.match(/^vault: restored (.+?) @/))) return `your notes were rewound to an earlier moment (${m[1]})`;
  if ((m = d.match(/^body: wrote (.+) \(h[\d-]+\)$/))) return `the agent wrote ${m[1]}`;
  if (/^body: undo/.test(d)) return "the agent's last change was undone — the timeline branched here";
  if (/^body: redo/.test(d)) return "an undone change was brought back";
  if ((m = d.match(/^merge: reconciled (\d+) heads$/))) return `${m[1]} branches were combined back into one`;
  return d;
}
function selectHist(c) {
  histSel = histSel === c ? null : c;
  const el = document.getElementById("histsel");
  const n = histNodes.find(x => x.change === histSel);
  if (!n) {
    histSel = null; el.classList.remove("on"); el.innerHTML = "";
    renderHistory();
    return;
  }
  el.classList.add("on");
  el.innerHTML = `<span class="rid">${esc(n.change)}</span>
    <span class="rdesc">${esc(histHuman(n))}</span>
    <span class="rfiles" id="rfiles">…</span>
    <button id="dorestore" title="copies your notes back to how they were at this moment — nothing is deleted; the rewind itself becomes a new step on the timeline">
      <i data-lucide="archive-restore"></i>rewind notes to here</button>`;
  document.getElementById("dorestore").onclick = async () => {
    const r = await (await fetch("/history/restore?rev=" + encodeURIComponent(n.change), { method: "POST", ...authed })).text();
    conslast.textContent = "rewind: " + r.trim();
    loadTree(); loadHistory();
    if (open.path && open.src !== "body") openFile(open.path, open.kind);   // reflect rewound content
  };
  refreshIcons();
  renderHistory();
  // what this moment touched (async — fills in when jj answers)
  fetch("/history/diff.json?rev=" + encodeURIComponent(n.change))
    .then(r => r.json())
    .then(d => {
      const f = document.getElementById("rfiles");
      if (!f || histSel !== n.change) return;
      const nice = (d.files || []).map(l => l.replace(/^[MAD] /, s =>
        ({ "M ": "· ", "A ": "+ ", "D ": "− " })[s]).replace("vault/", "").replace("body/", "⚙"));
      f.textContent = nice.length ? "touched: " + nice.join("  ") : "no file changes (a timeline marker)";
    }).catch(() => {});
}

document.getElementById("domerge").onclick = async () => {
  const r = await (await fetch("/history/merge", { method: "POST", ...authed })).text();
  conslast.textContent = "merge: " + r.trim();
  loadHistory();
};

new EventSource("/sse").onmessage = e => {
  conslast.textContent = e.data;
  conslast.classList.add("fresh");
  clearTimeout(freshTimer); freshTimer = setTimeout(() => conslast.classList.remove("fresh"), 2000);
  conspulse.classList.add("live");
  clearTimeout(pulseTimer); pulseTimer = setTimeout(() => conspulse.classList.remove("live"), 1200);

  // any edit anywhere → the timeline re-reads the real jj DAG (debounced)
  if (/history:|body: |vault: /.test(e.data)) histRefresh();

  if (/PROPOSAL|ACCEPTED|REVERTED|rejected|limb|ATTENTION|request queued/.test(e.data)) {
    recentEvents.unshift(e.data);
    if (recentEvents.length > 20) recentEvents.pop();
    renderNotifications();
    // voice link: the autopoet narrates notable events aloud
    if (commState === "voice" && voiceSpeaker)
      authedPost("/speak", e.data.replace(/^\d\d:\d\d:\d\d /, ""));
  }
  if (/PROPOSAL|ACCEPTED|REVERTED|rejected|limb registered/.test(e.data)) draw();
  // the agent authored/undid its body — refresh the world + the undo/redo buttons
  if (/body: (wrote|undone|redone)/.test(e.data)) { draw(); refreshUndoState(); }
};
loadHistory();

// after the editor slide animation settles, land the face on final center
document.getElementById("app").addEventListener("transitionend", ev => {
  if (ev.propertyName.startsWith("grid-template")) relayout();
});

// ══ APP-WIDE CONTEXT MENU ═══════════════════════════════════════════════
const ctx = document.getElementById("ctx");
function showCtx(x, y, items) {
  ctx.innerHTML = items.map((it, i) => it === "-" ? `<div class="sep"></div>` :
    `<div class="it ${it.danger ? "danger" : ""}" data-i="${i}">
       <i data-lucide="${it.icon}"></i>${esc(it.label)}</div>`).join("");
  ctx.querySelectorAll(".it").forEach(el =>
    el.onclick = () => { hideCtx(); items[+el.dataset.i].fn(); });
  ctx.style.left = Math.min(x, innerWidth - 200) + "px";
  ctx.style.top = Math.min(y, innerHeight - items.length * 34 - 12) + "px";
  ctx.classList.add("on");
  refreshIcons();
}
function hideCtx() { ctx.classList.remove("on"); }
addEventListener("click", e => { if (!ctx.contains(e.target)) hideCtx(); });
addEventListener("keydown", e => { if (e.key === "Escape") hideCtx(); });

