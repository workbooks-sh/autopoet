// ══ THE WORLD (graph) ═══════════════════════════════════════════════════
const COLORS = {
  self: "#223", doc: "#4a90d9", guide: "#8e7cc3", limb: "#e07a5f", request: "#d96ba0",
  library: "#2aa198", cluster: "#5a6472", system: "#9aa5b1",
  proposal: { pending:"#f2c14e", accepted:"#6aa84f", rejected:"#cc4125",
              "rejected-by-gate":"#a61c00", reverted:"#999" }
};
const color = n => n.type === "cluster" ? ((clusterById(n.clusterId) || {}).color || COLORS.cluster)
  : n.type === "proposal" ? (COLORS.proposal[n.status] || "#f2c14e") : (COLORS[n.type] || "#888");
const radius = n => n.type === "self" ? 46 : (n.type === "doc" ? 16 : n.type === "library" || n.type === "cluster" ? 18 : 13);

const svg = d3.select("#graph"), g = svg.append("g");
const zoomB = d3.zoom().scaleExtent([0.25, 3])
  .on("zoom", e => { g.attr("transform", e.transform); persistZoom(e.transform); syncSelfCube(); });
svg.call(zoomB);
// the camera survives reload
let zoomSaveT = null;
function persistZoom(t) {
  clearTimeout(zoomSaveT);
  zoomSaveT = setTimeout(() =>
    localStorage.setItem("ap-zoom", JSON.stringify({ x: t.x, y: t.y, k: t.k })), 300);
}
function restoreZoom() {
  try {
    const z = JSON.parse(localStorage.getItem("ap-zoom"));
    if (z) { svg.call(zoomB.transform, d3.zoomIdentity.translate(z.x, z.y).scale(z.k)); return true; }
  } catch (_) {}
  return false;
}
let worldData = { nodes: [], links: [] };
let nodeSel = null, linkSel = null;

// (the grid layout experiment was retired — force + clusters won)
["ap-layout", "ap-gridpos", "ap-zoom-grid", "ap-zoom-force"].forEach(k => localStorage.removeItem(k));

// ── clusters: named groups laid OVER the graph (view-state, never the filesystem).
// A cluster is manual (lasso/AI → explicit members) or a LIVE RULE (type:/text match,
// membership recomputed each draw). Collapsible into one compact node (the "pinch").
let clusters = [];
try { clusters = JSON.parse(localStorage.getItem("ap-clusters") || "[]"); } catch (_) {}
// the arrangement is YOURS: node positions persist across reload/restart
let forcePos = {};
try { forcePos = JSON.parse(localStorage.getItem("ap-forcepos") || "{}"); } catch (_) {}
function persistForcePos() {
  for (const n of (worldData.nodes || [])) if (n.x != null)
    forcePos[n.id] = { x: +n.x.toFixed(1), y: +n.y.toFixed(1) };
  localStorage.setItem("ap-forcepos", JSON.stringify(forcePos));
}
// a cluster remembers its internal SHAPE (each member's offset from the centroid);
// the layout springs members back to that arrangement instead of a shapeless blob
function captureClusterShapes() {
  let changed = false;
  for (const c of clusters) {
    if (c.collapsed) continue;
    const ms = clusterMembers(c, worldData.nodes)
      .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null);
    if (ms.length < 2) continue;
    const cx = d3.mean(ms, n => n.x), cy = d3.mean(ms, n => n.y);
    c.shape = {};
    for (const n of ms) c.shape[n.id] = { x: +(n.x - cx).toFixed(1), y: +(n.y - cy).toFixed(1) };
    changed = true;
  }
  if (changed) saveClusters();
}
const saveClusters = () => localStorage.setItem("ap-clusters", JSON.stringify(clusters));
const CLPAL = ["#8e7cc3", "#6aa84f", "#e07a5f", "#4a90d9", "#d96ba0", "#2aa198", "#c9a04e"];
function addCluster(c) {
  c.id = c.id || "cl" + Date.now().toString(36) + Math.floor(Math.random() * 1e4);
  c.color = c.color || CLPAL[clusters.length % CLPAL.length];
  clusters.push(c); clusterChanged();
  return c;
}
const clusterById = id => clusters.find(c => c.id === id);
function removeCluster(id) {
  const c = clusterById(id);
  clusters = clusters.filter(x => x.id !== id);
  saveClusters();
  if (c && c.collapsed) draw(); else clusterChanged();   // expanded: hull just melts away
}
// membership/name changes adjust the LIVE layout in place — never a full reset.
// (Only collapse/expand changes the node set and needs a real redraw.)
function clusterChanged() {
  saveClusters();
  if (!sim) return draw();
  const clustered = new Set();
  for (const c of clusters) if (!c.collapsed)
    for (const id of clusterMembers(c, worldData.nodes)) clustered.add(id);
  sim.force("collide", d3.forceCollide(d => radius(d) + (clustered.has(d.id) ? 36 : 14)));
  sim.alpha(0.3).restart();   // members drift in, hulls re-shape — nothing resets
}
// membership: explicit ids, or a live rule over the current nodes (self never joins)
function clusterMembers(c, nodes) {
  let ids;
  if (c.rule && c.rule.kind === "type") ids = nodes.filter(n => n.type === c.rule.value).map(n => n.id);
  else if (c.rule && c.rule.kind === "match") {
    const q = c.rule.value.toLowerCase();
    ids = nodes.filter(n => (n.label + " " + (n.detail || "") + " " + n.type).toLowerCase().includes(q)).map(n => n.id);
  } else ids = (c.members || []).filter(id => nodes.some(n => n.id === id));
  return ids.filter(id => id !== "self" && !id.startsWith("cluster:"));
}
// collapse pass (pre-layout): a collapsed cluster's members become ONE compact node;
// their links re-route to it, internal links vanish, duplicates dedupe.
function applyClusterTransform(data) {
  const owner = {};
  for (const c of clusters) if (c.collapsed)
    for (const id of clusterMembers(c, data.nodes)) if (!owner[id]) owner[id] = c;
  if (!Object.keys(owner).length) return data;
  const nodes = data.nodes.filter(n => !owner[n.id]);
  for (const c of clusters) if (c.collapsed) {
    const count = Object.values(owner).filter(x => x === c).length;
    if (count) nodes.push({ id: "cluster:" + c.id, type: "cluster", label: c.name, count,
      clusterId: c.id, detail: `cluster · ${count} nodes collapsed\n${c.note || ""}` });
  }
  const seen = new Set(), links = [];
  for (const l of data.links) {
    const sid = l.source.id !== undefined ? l.source.id : l.source;
    const tid = l.target.id !== undefined ? l.target.id : l.target;
    const s = owner[sid] ? "cluster:" + owner[sid].id : sid;
    const t = owner[tid] ? "cluster:" + owner[tid].id : tid;
    if (s === t) continue;
    const k = s + "→" + t + "·" + l.kind;
    if (!seen.has(k)) { seen.add(k); links.push({ source: s, target: t, kind: l.kind }); }
  }
  return { nodes, links };
}

// infinite Figma-style sheet: the paper is geometry in world space
const defs = svg.append("defs");
defs.append("pattern").attr("id", "grid-minor").attr("width", 24).attr("height", 24).attr("patternUnits", "userSpaceOnUse")
  .append("path").attr("d", "M 24 0 H 0 V 24").attr("fill", "none").attr("stroke", "var(--grid)").attr("stroke-width", 1);
defs.append("pattern").attr("id", "grid-major").attr("width", 120).attr("height", 120).attr("patternUnits", "userSpaceOnUse")
  .append("path").attr("d", "M 120 0 H 0 V 120").attr("fill", "none").attr("stroke", "var(--grid-major)").attr("stroke-width", 1.2);
const SHEET = 100000;
function paper(sel) {
  for (const id of ["grid-minor", "grid-major"])
    sel.append("rect").attr("x", -SHEET/2).attr("y", -SHEET/2).attr("width", SHEET).attr("height", SHEET)
       .attr("fill", `url(#${id})`).attr("pointer-events", "none");
}

