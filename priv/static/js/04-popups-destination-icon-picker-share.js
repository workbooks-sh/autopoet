// ── popups (destination + icon picker) share one floating element ──
const popEl = () => document.getElementById("iconpop");
function closePop() { const p = popEl(); p.className = ""; p.innerHTML = ""; }
function positionPop(anchor) {
  const p = popEl(), r = anchor.getBoundingClientRect();
  p.style.left = Math.max(8, r.left) + "px";
  p.style.top = (r.bottom + 6) + "px";
}
addEventListener("mousedown", e => {
  if (popEl().className && !popEl().contains(e.target) && !e.target.closest("#mIcon,#mDest")) closePop();
});

function collectDests(items, acc, depth) {
  for (const n of items || []) {
    if (n.type === "folder" || n.type === "workspace") {
      acc.push({ path: n.path, label: "  ".repeat(depth) + (n.type === "workspace" ? "# " : "") + n.name });
      collectDests(n.children, acc, depth + 1);
    }
  }
  return acc;
}
function openDestPop() {
  const dests = [{ path: "", label: "vault root" }, ...collectDests(vaultTree, [], 0)];
  const p = popEl(); p.className = "destpop on";
  p.innerHTML = `<div class="dlist">${dests.map(d =>
    `<button class="ditem ${d.path === mv.dest ? "sel" : ""}" data-dest="${esc(d.path)}">${esc(d.label)}</button>`).join("")}</div>`;
  positionPop(document.getElementById("mDest"));
  p.querySelectorAll(".ditem").forEach(b => b.onclick = () => { mv.dest = b.dataset.dest; closePop(); renderModal(); });
}
async function openIconPop() {
  if (!micnames) micnames = await (await fetch("/micons.json")).json();
  // file/type icons only — the folder icons aren't pickable (folders compose their own)
  const pool = micnames.filter(n => n !== "folder" && !n.startsWith("folder-"));
  const p = popEl(); p.className = "iconpicker on";
  p.innerHTML = `<input class="isearch" id="isearch" placeholder="search ${pool.length} icons…" spellcheck="false"><div class="igrid"></div>`;
  positionPop(document.getElementById("mIcon"));
  const grid = p.querySelector(".igrid");
  const render = q => {
    const list = q ? pool.filter(n => n.includes(q.toLowerCase())) : pool;
    grid.innerHTML = list.map(n =>
      `<button class="icell ${n === mv.icon ? "sel" : ""}" data-ic="${n}" title="${n}"><img src="${micUrl(n)}" loading="lazy"></button>`).join("");
    grid.querySelectorAll(".icell").forEach(b => b.onclick = () => { mv.icon = b.dataset.ic; closePop(); renderModal(); });
  };
  render("");
  const s = document.getElementById("isearch");
  s.oninput = () => render(s.value.trim());
  setTimeout(() => s.focus(), 40);
}

// ── body undo / redo (the agent writes .work directly; every write is reversible) ──
function applyUndoState(s) {
  document.getElementById("doundo").disabled = !s.undo;
  document.getElementById("doredo").disabled = !s.redo;
}
async function refreshUndoState() {
  try { applyUndoState(await (await fetch("/body/undostate.json")).json()); } catch (_) {}
}
async function bodyHistory(dir) {
  try {
    const s = await (await fetch("/body/" + dir, { method: "POST", ...authed })).json();
    applyUndoState(s);
    draw();                                   // the organism changed — refresh the world
    histRefresh();                            // …and the timeline moved (undo/redo = graph jumps)
    if (open.src === "body") openBody(open.path);   // a body page is open — reflect the change
  } catch (_) {}
}
document.getElementById("doundo").onclick = () => bodyHistory("undo");
document.getElementById("doredo").onclick = () => bodyHistory("redo");
refreshUndoState();

// ── sketch: MS-Paint bones, Excalidraw-grade ink (perfect-freehand), SVG out ──
const sk = document.getElementById("sketch");
const SVGNS = "http://www.w3.org/2000/svg";
let tool = "pen", drawing = null, anchor = null, ink = "#223344", skSize = 2, penPts = [];
const undoStack = [];

document.querySelectorAll("#skpal .tools button[data-tool]").forEach(b =>
  b.onclick = () => {
    tool = b.dataset.tool;
    document.querySelectorAll("#skpal .tools button[data-tool]").forEach(x => x.classList.toggle("sel", x === b));
  });
document.querySelectorAll("#skpal .sizes button").forEach(b =>
  b.onclick = () => {
    skSize = +b.dataset.size;
    document.querySelectorAll("#skpal .sizes button").forEach(x => x.classList.toggle("sel", x === b));
  });

const SWATCHES = ["#223344", "#e03131", "#2f6fdd", "#2f9e44", "#f2a33c", "#9c36b5", "#f76707", "#ffffff"];
document.getElementById("skswatches").innerHTML = SWATCHES.map((c, i) =>
  `<button data-c="${c}" class="${i === 0 ? "sel" : ""}" style="background:${c}"></button>`).join("");
document.querySelectorAll("#skswatches button").forEach(b =>
  b.onclick = () => {
    ink = b.dataset.c;
    document.querySelectorAll("#skswatches button").forEach(x => x.classList.toggle("sel", x === b));
  });

function commitEl(el) { undoStack.push({ op: "add", el }); onEdit(); }
function skUndo() {
  const u = undoStack.pop();
  if (!u) return;
  if (u.op === "add") u.el.remove();
  else u.parent.insertBefore(u.el, u.next);
  onEdit();
}
document.getElementById("skundo").onclick = skUndo;
addEventListener("keydown", e => {
  if ((e.metaKey || e.ctrlKey) && e.key === "z" &&
      document.getElementById("app").classList.contains("sketching")) {
    e.preventDefault(); skUndo();
  }
});

// perfect-freehand outline → SVG path (the standard quadratic-midpoint fill)
function pathFromStroke(pts) {
  if (!pts.length) return "";
  const d = pts.reduce((acc, [x0, y0], i, arr) => {
    const [x1, y1] = arr[(i + 1) % arr.length];
    acc.push(x0.toFixed(2), y0.toFixed(2), ((x0 + x1) / 2).toFixed(2), ((y0 + y1) / 2).toFixed(2));
    return acc;
  }, ["M", ...pts[0].slice(0, 2).map(n => n.toFixed(2)), "Q"]);
  d.push("Z");
  return d.join(" ");
}
function renderPen() {
  if (!drawing) return;
  if (window.getStroke) {
    const outline = getStroke(penPts, {
      size: skSize * 3.4, thinning: 0.55, smoothing: 0.5, streamline: 0.45,
      simulatePressure: penPts.every(p => p[2] === 0.5)
    });
    drawing.setAttribute("d", pathFromStroke(outline));
    drawing.setAttribute("fill", ink);
    drawing.removeAttribute("stroke");
  } else {
    drawing.setAttribute("d", "M " + penPts.map(p => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" L "));
  }
}
function eraseAt(e) {
  const hit = document.elementFromPoint(e.clientX, e.clientY);
  if (hit && hit !== sk && sk.contains(hit) && hit.tagName !== "defs" && !hit.closest("defs")) {
    undoStack.push({ op: "del", el: hit, parent: hit.parentNode, next: hit.nextSibling });
    hit.remove();
  }
}

function loadSketch(svgText) {
  const doc = new DOMParser().parseFromString(svgText, "image/svg+xml");
  sk.setAttribute("viewBox", doc.documentElement.getAttribute("viewBox") || "0 0 1200 800");
  sk.innerHTML = doc.documentElement.innerHTML;   // saved sketches carry their own defs
}
// arrowheads follow the ink color: one marker per used color
function ensureArrowMarker(c) {
  const id = "arr" + c.replace(/[^a-zA-Z0-9]/g, "");
  if (sk.querySelector("#" + id)) return id;
  let defs = sk.querySelector("defs");
  if (!defs) { defs = document.createElementNS(SVGNS, "defs"); sk.prepend(defs); }
  const m = document.createElementNS(SVGNS, "marker");
  m.setAttribute("id", id); m.setAttribute("viewBox", "0 0 10 10");
  m.setAttribute("refX", 8); m.setAttribute("refY", 5);
  m.setAttribute("markerWidth", 7); m.setAttribute("markerHeight", 7);
  m.setAttribute("orient", "auto-start-reverse");
  m.innerHTML = `<path d="M 0 0 L 10 5 L 0 10 z" fill="${c}"/>`;
  defs.appendChild(m);
  return id;
}
function serializeSketch() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${sk.getAttribute("viewBox")}" fill="none">\n${sk.innerHTML}\n</svg>`;
}
function skPt(e) {
  return new DOMPoint(e.clientX, e.clientY).matrixTransform(sk.getScreenCTM().inverse());
}
const stroke = el => {
  el.setAttribute("stroke", ink); el.setAttribute("stroke-width", skSize + 0.5);
  el.setAttribute("stroke-linecap", "round"); el.setAttribute("fill", "none");
  return el;
};

sk.addEventListener("pointerdown", e => {
  if (tool === "text") return placeText(e);
  sk.setPointerCapture(e.pointerId);
  const p = skPt(e); anchor = p;
  if (tool === "eraser") { drawing = "erasing"; eraseAt(e); return; }
  if (tool === "pen") {
    penPts = [[p.x, p.y, e.pressure || 0.5]];
    drawing = document.createElementNS(SVGNS, "path");
    renderPen();
  } else if (tool === "rect") {
    drawing = stroke(document.createElementNS(SVGNS, "rect"));
    drawing.setAttribute("rx", 6);
  } else if (tool === "ellipse") {
    drawing = stroke(document.createElementNS(SVGNS, "ellipse"));
  } else if (tool === "arrow") {
    drawing = stroke(document.createElementNS(SVGNS, "line"));
    drawing.setAttribute("x1", p.x); drawing.setAttribute("y1", p.y);
    drawing.setAttribute("marker-end", `url(#${ensureArrowMarker(ink)})`);
  }
  if (drawing && drawing !== "erasing") sk.appendChild(drawing);
});
sk.addEventListener("pointermove", e => {
  if (!drawing) return;
  if (drawing === "erasing") return eraseAt(e);
  const p = skPt(e);
  if (tool === "pen") {
    penPts.push([p.x, p.y, e.pressure || 0.5]);
    renderPen();
  } else if (tool === "rect") {
    drawing.setAttribute("x", Math.min(anchor.x, p.x)); drawing.setAttribute("y", Math.min(anchor.y, p.y));
    drawing.setAttribute("width", Math.abs(p.x - anchor.x)); drawing.setAttribute("height", Math.abs(p.y - anchor.y));
  } else if (tool === "ellipse") {
    drawing.setAttribute("cx", (anchor.x + p.x) / 2); drawing.setAttribute("cy", (anchor.y + p.y) / 2);
    drawing.setAttribute("rx", Math.abs(p.x - anchor.x) / 2); drawing.setAttribute("ry", Math.abs(p.y - anchor.y) / 2);
  } else if (tool === "arrow") {
    drawing.setAttribute("x2", p.x); drawing.setAttribute("y2", p.y);
  }
});
addEventListener("pointerup", () => {
  if (!drawing) return;
  if (drawing === "erasing") { drawing = null; onEdit(); return; }
  // discard accidental dots (shapes with no size)
  const tiny = (tool === "rect" && +drawing.getAttribute("width") < 3) ||
               (tool === "ellipse" && +drawing.getAttribute("rx") < 2);
  if (tiny) drawing.remove(); else commitEl(drawing);
  drawing = null; penPts = [];
});

// text tool: click places an in-place input; Enter commits an SVG <text>
const sktext = document.getElementById("sktext");
let textAt = null;
function placeText(e) {
  textAt = skPt(e);
  sktext.style.display = "block";
  sktext.style.left = (e.clientX - document.getElementById("editor").getBoundingClientRect().left) + "px";
  sktext.style.top = (e.clientY - document.getElementById("editor").getBoundingClientRect().top) + "px";
  sktext.value = "";
  setTimeout(() => sktext.focus(), 30);
}
sktext.addEventListener("keydown", e => {
  if (e.key === "Enter" && sktext.value.trim()) {
    const t = document.createElementNS(SVGNS, "text");
    t.setAttribute("x", textAt.x); t.setAttribute("y", textAt.y);
    t.setAttribute("fill", ink);
    t.setAttribute("font-family", "-apple-system, sans-serif");
    t.setAttribute("font-size", 12 + skSize * 4);
    t.textContent = sktext.value.trim();
    sk.appendChild(t);
    sktext.style.display = "none";
    commitEl(t);
  }
  if (e.key === "Escape") sktext.style.display = "none";
});
sktext.addEventListener("blur", () => sktext.style.display = "none");

