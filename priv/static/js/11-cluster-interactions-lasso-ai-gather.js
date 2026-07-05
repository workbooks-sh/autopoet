// ── cluster interactions: lasso · AI · gather · panel · ctx ──
function inPoly(pt, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i], [xj, yj] = poly[j];
    if ((yi > pt[1]) !== (yj > pt[1]) && pt[0] < (xj - xi) * (pt[1] - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
// lasso SELECTS (dotted highlight) — it never groups by itself. Shift-lasso adds to
// the selection; the floating toolbar then groups / clears. Lasso mode stays on for
// repeated sweeps until the button or Escape ends it.
let lassoOn = false, lassoPts = [], lassoEl = null, lassoShift = false;
let selectedIds = new Set();
function setLassoMode(on) {
  lassoOn = on;
  svg.style("cursor", on ? "crosshair" : null);
  if (on) svg.on(".zoom", null); else svg.call(zoomB);   // pan pauses while lassoing
}
function clearSelection() { selectedIds.clear(); updateSelectionUI(); }
function updateSelectionUI() {
  if (nodeSel) nodeSel.classed("selnode", d => selectedIds.has(d.id));
  const st = document.getElementById("seltool");
  if (!selectedIds.size) return st.classList.remove("on");
  st.querySelector(".selcount").textContent = selectedIds.size + " selected";
  const r = document.getElementById("stage").getBoundingClientRect();
  st.style.left = (r.left + r.width / 2) + "px";
  st.style.top = (r.bottom - 60) + "px";
  st.classList.add("on");
  refreshIcons();
}
svg.on("mousedown.lasso", e => {
  if (!lassoOn) return;
  e.preventDefault();
  lassoShift = e.shiftKey;
  lassoPts = [d3.pointer(e, g.node())];
  lassoEl = g.append("path").attr("class", "lasso");
});
svg.on("mousemove.lasso", e => {
  if (!lassoOn || !lassoEl) return;
  lassoPts.push(d3.pointer(e, g.node()));
  lassoEl.attr("d", "M" + lassoPts.map(p => p.join(",")).join("L"));
});
svg.on("mouseup.lasso", () => {
  if (!lassoOn || !lassoEl) return;
  const poly = lassoPts; lassoEl.remove(); lassoEl = null;
  if (poly.length < 3) return;
  const ids = worldData.nodes.filter(n =>
    n.id !== "self" && n.type !== "cluster" && n.x != null && inPoly([n.x, n.y], poly)).map(n => n.id);
  if (!lassoShift) selectedIds.clear();
  ids.forEach(id => selectedIds.add(id));
  updateSelectionUI();
  if (!ids.length && !lassoShift) toast("lasso caught nothing");
  if (!lassoShift) setLassoMode(false);   // shift keeps the lasso alive for more sweeps
});
addEventListener("keydown", e => { if (e.key === "Escape" && lassoOn) setLassoMode(false); });
// the floating selection toolbar
document.getElementById("sel-group").onclick = async () => {
  setLassoMode(false);
  const picked = await askClusterName(selectedIds.size);
  if (picked) { addCluster({ name: picked.name, color: picked.color, members: [...selectedIds] }); clearSelection(); }
};
document.getElementById("sel-clear").onclick = () => { setLassoMode(false); clearSelection(); };
// name + colour picker for a new cluster (palette from CLPAL)
function askClusterName(count) {
  return new Promise(resolve => {
    let picked = CLPAL[clusters.length % CLPAL.length];
    openModalRaw(`<h3>GROUP ${count} NODE${count === 1 ? "" : "S"}</h3>
      <input id="modalname" placeholder="name the cluster" spellcheck="false">
      <div class="clpal">${CLPAL.map(col => `<button class="swb" data-c="${col}" style="background:${col}"></button>`).join("")}</div>
      <div class="acts"><button id="modalcancel">cancel</button><button class="go" id="modalgo">create</button></div>`);
    const sync = () => document.querySelectorAll("#modal .swb").forEach(b => b.classList.toggle("sel", b.dataset.c === picked));
    sync();
    document.querySelectorAll("#modal .swb").forEach(b => b.onclick = () => { picked = b.dataset.c; sync(); });
    const inp = document.getElementById("modalname");
    setTimeout(() => inp.focus(), 60);
    const done = v => { closeModal(); resolve(v); };
    document.getElementById("modalcancel").onclick = () => done(null);
    document.getElementById("modalgo").onclick = () => done(inp.value.trim() ? { name: inp.value.trim(), color: picked } : null);
    inp.onkeydown = e => {
      if (e.key === "Enter") done(inp.value.trim() ? { name: inp.value.trim(), color: picked } : null);
      if (e.key === "Escape") done(null);
    };
  });
}
// AI clustering: prompt + node catalog → the model's named groups become clusters
async function aiCluster(promptText) {
  toast("clustering…");
  const catalog = worldData.nodes.filter(n => n.id !== "self" && n.type !== "cluster")
    .map(n => `${n.id}\t${n.type}\t${n.label}`).join("\n");
  try {
    const res = await (await fetch("/graph/cluster", { method: "POST", body: promptText + "\n" + catalog, ...authed })).json();
    if (res.error) return toast("ai cluster failed: " + res.error);
    const valid = new Set(worldData.nodes.map(n => n.id));
    let made = 0;
    for (const grp of res.clusters || []) {
      const members = grp.members.filter(id => valid.has(id));
      if (members.length) { addCluster({ name: grp.name, members }); made++; }
    }
    toast(made ? `${made} cluster${made === 1 ? "" : "s"} created` : "the model found no groups");
  } catch (err) { toast("ai cluster failed"); }
}
