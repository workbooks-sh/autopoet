// ── node details panel ────────────────────────────────────────────────────
const panel = document.getElementById("panel");
function showPanel(d) {
  let html = "";
  if (d.path) html += `<button class="pencil" onclick="openBody('${esc(d.path)}')" title="edit in the editor"><i data-lucide="pencil"></i></button>`;
  html += `<h3>${esc(d.label)}</h3><span class="tag" style="background:${color(d)}">${d.type}${d.status ? " · " + d.status : ""}</span>`;
  if (d.type === "proposal" && d.status === "pending") {
    const id = d.id.slice(5);
    html += `<div style="margin-bottom:8px">
      <button class="ok" onclick="act('${id}','accept')">Accept</button>
      <button class="no" onclick="rejectWithReason('${id}')">Reject</button></div>`;
  }
  if (d.type === "proposal" && d.status === "accepted") {
    const id = d.id.slice(5);
    html += `<div style="margin-bottom:8px"><button onclick="act('${id}','revert')">Revert</button></div>`;
  }
  html += `<pre>${esc(d.detail || "")}</pre>`;
  panel.innerHTML = html; panel.style.display = "block";
  refreshIcons();
}
document.addEventListener("keydown", e => { if (e.key === "Escape") panel.style.display = "none"; });
svg.on("click", e => { if (e.target.id === "graph") panel.style.display = "none"; });
svg.on("contextmenu", e => {
  if (e.target.id !== "graph" && e.target.tagName !== "rect") return;
  e.preventDefault();
  showCtx(e.clientX, e.clientY, [
    { icon: "file-plus-2", label: "new document", fn: () => openModal("note") },
    { icon: "pen-tool", label: "new sketch", fn: () => openModal("sketch") },
    { icon: "folder-plus", label: "new folder", fn: () => openModal("folder") }, "-",
    { icon: "bell", label: "notifications", fn: () => document.getElementById("cb-bell").click() }
  ]);
});
function act(id, verb) {
  fetch(`/proposal/${id}/${verb}`, { method: "POST", ...authed })
    .then(() => { panel.style.display = "none"; draw(); });
}
function rejectWithReason(id) {
  const reason = prompt("Reject reason (teaches the brain — optional):") || "";
  fetch(`/proposal/${id}/reject?reason=${encodeURIComponent(reason)}`, { method: "POST", ...authed })
    .then(() => { panel.style.display = "none"; draw(); });
}

// ── layout: panel changes only resize the VIEWPORT — the world never resets.
// Centering happens once, at draw (load/reload); after that the canvas is yours.
function relayout() {
  const stage = document.getElementById("stage");
  svg.attr("width", stage.clientWidth).attr("height", stage.clientHeight);
}
addEventListener("resize", relayout);

// pane resizing (tree / editor widths, console height) via CSS vars
function dragVar(handle, cssVar, compute) {
  handle.addEventListener("pointerdown", e => {
    e.preventDefault();
    handle.setPointerCapture(e.pointerId);
    document.getElementById("app").classList.add("dragging");  // 1:1, no easing mid-drag
    const move = ev => document.documentElement.style.setProperty(cssVar, compute(ev) + "px");
    const up = () => {
      removeEventListener("pointermove", move); removeEventListener("pointerup", up);
      document.getElementById("app").classList.remove("dragging");
      relayout();
    };
    addEventListener("pointermove", move); addEventListener("pointerup", up);
  });
}
// min 272px keeps the top-right commands (undo/redo + cmd/live) clear of the macOS stoplight
dragVar(document.getElementById("treers"), "--tree-w", ev => Math.max(272, Math.min(460, ev.clientX)));
dragVar(document.getElementById("edrs"), "--ed-w",
  ev => Math.max(300, Math.min(innerWidth * 0.6, ev.clientX - document.getElementById("tree").offsetWidth)));
dragVar(document.getElementById("consgrip"), "--cons-h",
  ev => Math.max(26, Math.min(innerHeight * 0.5, innerHeight - ev.clientY)));

// ── console: the HISTORY MANAGER (collapsed by default; SSE drives the ticker) ──
const conslast = document.getElementById("conslast");
const conspulse = document.getElementById("conspulse");
const conscount = document.getElementById("conscount");
let consOpen = false, pulseTimer = null, freshTimer = null;

function setConsole(open) {
  consOpen = open;
  document.getElementById("app").classList.toggle("console-open", open);
  document.documentElement.style.setProperty("--cons-h", open ? "260px" : "30px");
  if (open) loadHistory();
  // re-center the face to the final pane size once the track animation settles
  setTimeout(relayout, 320);
}
document.getElementById("conshead").onclick = e => {
  if (e.target.closest("#consgrip") || e.target.closest("#histbtns")) return;
  setConsole(!consOpen);
};

// ══ THE HISTORY MANAGER ════════════════════════════════════════════════════
// The console renders the REAL commit DAG of the jj repo at data/history —
// every vault + body edit is a commit; undo/redo are graph moves; merges are
// true multi-parent commits. GitKraken bones, terminal skin. All colors come
// from the --hist-* theme tokens so the graph follows light/dark.
const histTok = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const laneColors = () => [0, 1, 2, 3, 4, 5, 6].map(i => histTok("--hist-lane-" + i));
let histNodes = [], histSel = null, histTimer = null;

const histKind = (d, at) =>
  (!d && at) ? "k-now" :
  d.startsWith("vault:") ? "k-vault" :
  d.startsWith("merge:") ? "k-merge" :
  /^body: (undo|redo)/.test(d) ? "k-move" :
  d.startsWith("body:") ? "k-body" : "";

async function loadHistory() {
  try { histNodes = await (await fetch("/history/log.json")).json(); } catch (_) { histNodes = []; }
  renderHistory();
}
const histRefresh = () => { clearTimeout(histTimer); histTimer = setTimeout(loadHistory, 300); };

function renderHistory() {
  const rowsEl = document.getElementById("histrows");
  const svg = document.getElementById("histsvg");

  if (!histNodes.length) {
    rowsEl.innerHTML = `<div id="histempty">no history yet — every vault + body edit lands here as a real commit</div>`;
    svg.innerHTML = ""; svg.setAttribute("width", 0); svg.setAttribute("height", 0);
    conscount.textContent = "";
    return;
  }

  // heads = described nodes nobody described points to as a parent (the open tips)
  const described = histNodes.filter(n => n.desc);
  const referenced = new Set(described.flatMap(n => n.parents));
  const heads = new Set(described.filter(n => !referenced.has(n.change)).map(n => n.change));

  // lane assignment over newest-first topological rows (children precede parents)
  const R = 22, COL = 13, PADX = 14;
  const lane = {}, row = {}, active = [];
  const free = () => { const i = active.indexOf(null); return i === -1 ? active.length : i; };
  histNodes.forEach((c, i) => {
    row[c.change] = i;
    let l = active.indexOf(c.change);
    if (l === -1) l = free();
    active[l] = null;
    lane[c.change] = l;
    c.parents.forEach((p, k) => {
      if (active.indexOf(p) === -1) active[k === 0 && active[l] === null ? l : free()] = p;
    });
  });

  const maxLane = Math.max(...histNodes.map(c => lane[c.change]));
  const gutter = PADX * 2 + maxLane * COL;
  const X = l => PADX + l * COL, Y = i => i * R + R / 2;
  svg.setAttribute("width", gutter + 6);
  svg.setAttribute("height", histNodes.length * R);

  const LC = laneColors();
  let edges = "", dots = "";
  histNodes.forEach(c => c.parents.forEach(p => {
    if (!(p in row)) return;   // parent beyond the log window
    const x1 = X(lane[c.change]), y1 = Y(row[c.change]);
    const x2 = X(lane[p]), y2 = Y(row[p]);
    const cl = LC[(x1 === x2 ? lane[c.change] : Math.max(lane[c.change], lane[p])) % LC.length];
    edges += x1 === x2
      ? `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${cl}" stroke-width="2"/>`
      : `<path d="M${x1},${y1} C${x1},${y1 + R * .85} ${x2},${y2 - R * .85} ${x2},${y2}" stroke="${cl}" stroke-width="2" fill="none"/>`;
  }));
  const [cMerge, cMove, cNow, cHole] = [histTok("--hist-merge"), histTok("--hist-move"), histTok("--hist-now"), histTok("--hist-bg")];
  histNodes.forEach(c => {
    const x = X(lane[c.change]), y = Y(row[c.change]);
    const cl = LC[lane[c.change] % LC.length];
    const d = c.desc || "";
    if (c.parents.length > 1)                            // a true merge commit
      dots += `<circle cx="${x}" cy="${y}" r="5.5" fill="none" stroke="${cMerge}" stroke-width="2"/><circle cx="${x}" cy="${y}" r="2" fill="${cMerge}"/>`;
    else if (/^body: (undo|redo)/.test(d))               // a timeline jump marker
      dots += `<circle cx="${x}" cy="${y}" r="4" fill="${cHole}" stroke="${cMove}" stroke-width="2"/>`;
    else if (!d && c.at)                                 // @ — the live working copy
      dots += `<circle cx="${x}" cy="${y}" r="6.5" fill="${cNow}" opacity=".22"/><circle cx="${x}" cy="${y}" r="3" fill="${cNow}"/>`;
    else
      dots += `<circle cx="${x}" cy="${y}" r="4" fill="${cl}"/>`;
    if (c.change === histSel)                            // inspecting = a ring, never a mask
      dots += `<circle cx="${x}" cy="${y}" r="8.5" fill="none" stroke="${cl}" stroke-width="1.5" opacity=".55"/>`;
  });
  svg.innerHTML = edges + dots;

  // the combine prompt only exists while the timeline is actually split
  const mergeBtn = document.getElementById("domerge");
  mergeBtn.style.display = heads.size > 1 ? "flex" : "none";
  document.getElementById("domergelbl").textContent =
    heads.size > 1 ? `combine ${heads.size} branches` : "";

  rowsEl.innerHTML = histNodes.map(c => {
    const d = c.desc || (c.at ? "· working copy (uncommitted)" : "");
    return `<div class="hrow ${histSel === c.change ? "sel" : ""} ${heads.has(c.change) ? "head" : ""}"
      data-c="${c.change}" style="padding-left:${gutter + 8}px">
      <span class="hid">${esc(c.change)}</span>
      <span class="hdesc ${histKind(c.desc, c.at)}">${esc(d)}</span>
      <span class="htime">${esc(c.time)}</span></div>`;
  }).join("");
  rowsEl.querySelectorAll(".hrow").forEach(el => el.onclick = () => selectHist(el.dataset.c));

  conscount.textContent = histNodes.length + " nodes" + (heads.size > 1 ? ` · ${heads.size} heads` : "");
}

