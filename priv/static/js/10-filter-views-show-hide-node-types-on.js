// ── filter · views: show/hide node types on the canvas ──
// modeled as HIDDEN types so anything new (e.g. a first cluster) defaults visible.
// GENESIS (I3): the server ships default_hidden (guide/system/library — plumbing);
// adopted once on first load, then the user's choices persist in localStorage.
let hiddenTypes = new Set(JSON.parse(localStorage.getItem("ap-hidden") || "null") || []);
let hiddenAdopted = localStorage.getItem("ap-hidden") !== null;
const saveHidden = () => localStorage.setItem("ap-hidden", JSON.stringify([...hiddenTypes]));
const typeSwatch = t => t === "proposal" ? COLORS.proposal.pending : (COLORS[t] || "#888");
const typeLabel = t => t === "self" ? "autopoet" : t;
function presentTypes() {
  const m = new Map();
  (worldData.nodes || []).forEach(n => m.set(n.type, (m.get(n.type) || 0) + 1));
  return [...m.entries()];
}
function applyFilter() {
  if (!nodeSel) return;
  const on = t => !hiddenTypes.has(t);
  const typeOf = e => {   // link ends: node objects (force) or raw ids (grid)
    const id = e && e.id !== undefined ? e.id : e;
    const n = (worldData.nodes || []).find(x => x.id === id);
    return n ? n.type : null;
  };
  nodeSel.attr("opacity", d => on(d.type) ? 1 : 0.05).style("pointer-events", d => on(d.type) ? "all" : "none");
  if (linkSel) linkSel.attr("opacity", l => (on(typeOf(l.source)) && on(typeOf(l.target))) ? 1 : 0.04);
  // hiding is never invisible-invisible: a pill on the graph-tools badge counts it
  const fb = document.getElementById("cb-filter");
  if (fb) {
    let pill = document.getElementById("flt-pill");
    if (!pill) { pill = document.createElement("span"); pill.id = "flt-pill"; fb.appendChild(pill); }
    const hc = (worldData.nodes || []).filter(n => hiddenTypes.has(n.type)).length;
    pill.textContent = hc ? `${hc} hidden` : "";
    pill.style.display = hc ? "" : "none";
  }
}
function closeFilterPop() { document.getElementById("filterpop").classList.remove("on"); }
let fltShowOpen = false, fltAiOpen = false;
function openFilterPop() {
  const p = document.getElementById("filterpop");
  if (p.classList.contains("on")) return closeFilterPop();
  const clusterRows = clusters.map(c => {
    const n = clusterMembers(c, worldData.nodes).length + (c.collapsed ? (worldData.nodes.find(x => x.clusterId === c.id) || {}).count || 0 : 0);
    return `<div class="flt-row flt-cl" data-cl="${c.id}">
      <span class="flt-sw" style="background:${c.color};border-radius:50%"></span>
      <span class="flt-l">${esc(c.name)}</span><span class="flt-n">${n}</span>
      <button class="flt-ic" data-act="collapse" title="${c.collapsed ? "expand" : "collapse to one node"}"><i data-lucide="${c.collapsed ? "maximize-2" : "minimize-2"}"></i></button>
      <button class="flt-ic" data-act="kill" title="dissolve"><i data-lucide="x"></i></button>
    </div>`;
  }).join("");
  p.innerHTML = `
    <div class="flt-title">tools</div>
    <div class="flt-tools">
      <button class="flt-tool" id="flt-lasso" title="lasso — sweep nodes into a selection"><i data-lucide="lasso"></i></button>
      <button class="flt-tool ${fltAiOpen ? "sel" : ""}" id="flt-aitool" title="ask — describe a grouping in plain words"><i data-lucide="sparkles"></i></button>
    </div>
    <div class="flt-composer" id="flt-composer" style="display:${fltAiOpen ? "block" : "none"}">
      <textarea id="flt-ai" rows="3" spellcheck="false"
        placeholder="describe a grouping — “split the docs by theme”, “group everything about the business”…"></textarea>
      <div class="flt-compbar"><span class="hint">⌘⏎</span>
        <button id="flt-aigo"><i data-lucide="sparkles"></i>cluster</button></div>
    </div>
    <div class="flt-sep"></div>
    <div class="flt-title">clusters</div>
    ${clusterRows || `<div class="flt-note">// none yet — lasso nodes, or ask</div>`}
    <div class="flt-sep"></div>
    <button class="flt-collhead" id="flt-showhead"><i data-lucide="chevron-${fltShowOpen ? "down" : "right"}"></i>filter</button>
    <div id="flt-showsec" style="display:${fltShowOpen ? "block" : "none"}">
      ${presentTypes().map(([t, n]) =>
        `<label class="flt-row"><input type="checkbox" data-t="${t}" ${hiddenTypes.has(t) ? "" : "checked"}>
           <span class="flt-sw" style="background:${typeSwatch(t)}"></span>
           <span class="flt-l">${esc(typeLabel(t))}</span><span class="flt-n">${n}</span></label>`).join("")}
      <button class="flt-all" id="flt-all">reset · show all</button>
    </div>`;
  p.classList.add("on");
  refreshIcons();
  const r = document.getElementById("cb-filter").getBoundingClientRect();
  p.style.top = (r.bottom + 8) + "px"; p.style.right = (innerWidth - r.right) + "px"; p.style.left = "auto";
  // tools
  document.getElementById("flt-lasso").onclick = () => {
    closeFilterPop(); setLassoMode(true);
    toast("sweep around nodes — shift adds more, esc finishes");
  };
  document.getElementById("flt-aitool").onclick = () => {
    fltAiOpen = !fltAiOpen;
    document.getElementById("flt-composer").style.display = fltAiOpen ? "block" : "none";
    document.getElementById("flt-aitool").classList.toggle("sel", fltAiOpen);
    if (fltAiOpen) setTimeout(() => document.getElementById("flt-ai").focus(), 40);
  };
  const aiIn = document.getElementById("flt-ai");
  const mkAi = () => { const v = aiIn.value.trim(); if (v) { closeFilterPop(); aiCluster(v); } };
  document.getElementById("flt-aigo").onclick = mkAi;
  aiIn.onkeydown = e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); mkAi(); } };
  // cluster rows: name click = panel; collapse/dissolve inline
  p.querySelectorAll(".flt-cl").forEach(row => {
    const c = clusterById(row.dataset.cl);
    row.querySelector(".flt-l").onclick = () => { closeFilterPop(); showClusterPanel(c); };
    row.querySelector('[data-act="collapse"]').onclick = () => { c.collapsed = !c.collapsed; saveClusters(); closeFilterPop(); draw(); };
    row.querySelector('[data-act="kill"]').onclick = () => { removeCluster(c.id); closeFilterPop(); };
  });
  // the collapsible filter section
  document.getElementById("flt-showhead").onclick = () => {
    fltShowOpen = !fltShowOpen;
    document.getElementById("flt-showsec").style.display = fltShowOpen ? "block" : "none";
    document.querySelector("#flt-showhead svg")?.remove();
    document.getElementById("flt-showhead").insertAdjacentHTML("afterbegin",
      `<i data-lucide="chevron-${fltShowOpen ? "down" : "right"}"></i>`);
    refreshIcons();
  };
  p.querySelectorAll("#flt-showsec input[type=checkbox]").forEach(cb => cb.onchange = () => {
    cb.checked ? hiddenTypes.delete(cb.dataset.t) : hiddenTypes.add(cb.dataset.t);
    saveHidden(); draw();   // hidden types live outside the sim — re-draw the world
  });
  document.getElementById("flt-all").onclick = () => { hiddenTypes.clear(); saveHidden(); closeFilterPop(); draw(); };
}

