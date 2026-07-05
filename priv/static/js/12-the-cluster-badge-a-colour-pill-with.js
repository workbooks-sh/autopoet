// ── the cluster badge: a colour pill with a grip handle — grab it to move the
// WHOLE cluster; a plain click opens the cluster panel ──
// white text on saturated colours, black only when the pill is genuinely light
function badgeInk(hex) {
  const n = parseInt((hex || "#888").slice(1), 16);
  const lum = 0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255);
  return lum > 186 ? "#1c2230" : "#fff";
}
function drawClusterBadge(gp, c, x, y) {
  const ink = badgeInk(c.color);
  const pinned = !!(c.badge && c.badge.world);
  const bw = 30 + c.name.length * 7.4;
  const b = gp.append("g").attr("transform", `translate(${x - bw / 2},${y})`)
    .style("cursor", "grab")
    .on("mousedown", e => beginClusterDrag(e, c))   // the handle always moves the cluster (anchor tows along)
    .on("contextmenu", e => { e.preventDefault(); e.stopPropagation(); badgeCtx(e, c, x, y); });
  b.append("rect").attr("width", bw).attr("height", 22).attr("rx", 11)
    .attr("fill", c.color).attr("fill-opacity", .92)
    .attr("stroke", pinned ? "#1c2230" : "none").attr("stroke-width", pinned ? 1.4 : 0)
    .attr("stroke-dasharray", pinned ? "3 2.5" : null);   // dashed ring = pinned to world space
  for (let gy = 0; gy < 3; gy++) for (let gx = 0; gx < 2; gx++)
    b.append("circle").attr("cx", 10 + gx * 4).attr("cy", 7 + gy * 4).attr("r", 1.15)
      .attr("fill", ink).attr("fill-opacity", .75);
  b.append("text").attr("x", 22).attr("y", 15).attr("class", "cl-badge-t").attr("fill", ink).text(c.name);
}
let clDrag = null;
function beginClusterDrag(e, c) {
  e.preventDefault(); e.stopPropagation();
  const drag = { c, start: d3.pointer(e, g.node()), snap: {}, moved: false,
                 badgeOrig: c.badge && c.badge.world ? { ...c.badge } : null };
  for (const id of clusterMembers(c, worldData.nodes)) {
    const n = worldData.nodes.find(x => x.id === id);
    if (n && n.x != null) { drag.snap[id] = { x: n.x, y: n.y }; n.fx = n.x; n.fy = n.y; }
  }
  if (sim) sim.alphaTarget(0.06).restart();
  clDrag = drag;
}
addEventListener("mousemove", e => {
  if (!clDrag) return;
  const p = d3.pointer(e, g.node());
  const dx = p[0] - clDrag.start[0], dy = p[1] - clDrag.start[1];
  if (Math.hypot(dx, dy) > 4) clDrag.moved = true;
  for (const [id, s] of Object.entries(clDrag.snap)) {
    const n = worldData.nodes.find(x => x.id === id);
    if (n) { n.fx = s.x + dx; n.fy = s.y + dy; }
  }
  if (clDrag.badgeOrig) {   // an anchored cluster tows its anchor along
    const bo = clDrag.badgeOrig;
    clDrag.c.badge = { x: bo.x + dx, y: bo.y + dy, cx: bo.cx + dx, cy: bo.cy + dy, world: true };
  }
});
addEventListener("mouseup", () => {
  if (!clDrag) return;
  const { c, moved, snap } = clDrag;
  clDrag = null;
  for (const id of Object.keys(snap)) {
    const n = worldData.nodes.find(x => x.id === id);
    if (n && n.id !== "self") { n.fx = null; n.fy = null; }
  }
  if (sim) sim.alphaTarget(0);
  captureClusterShapes(); persistForcePos();
  if (!moved) showClusterPanel(c);   // a click (no drag) opens the panel
});

// ── hull geometry (shared by the renderer, live join tests, and shape pins) ──
const memberCentroid = pts => [d3.mean(pts, p => p[0]), d3.mean(pts, p => p[1])];
// a cluster's hull is shaped by its members PLUS any purely-cosmetic shape pins.
// A pin's stored offset is its VISUAL spot ON the membrane stroke (relative to the
// member centroid, so it travels with the cluster); for the hull geometry the point
// is pulled ~pad inward so the drawn outline passes through the pin.
// a pin either RIDES the cluster (offset from the member centroid) or is PINNED TO
// WORLD SPACE (absolute x/y — it stays put and the membrane stretches around it)
const pinVisual = (p, cx, cy) => p.world ? [p.x, p.y] : [cx + p.dx, cy + p.dy];
function withPins(c, mpts) {
  if (!(c.pins || []).length || !mpts.length) return mpts;
  const [cx, cy] = memberCentroid(mpts);
  return mpts.concat(c.pins.map(p => {
    const [vx, vy] = pinVisual(p, cx, cy);
    const dx = vx - cx, dy = vy - cy;
    const L = Math.hypot(dx, dy) || 1, pull = Math.min(44, L * 0.8);
    return [vx - dx / L * pull, vy - dy / L * pull];
  }));
}
// the visual (on-stroke) pin positions for a cluster
function pinPoints(c, mpts) {
  const [cx, cy] = memberCentroid(mpts);
  return (c.pins || []).map(p => pinVisual(p, cx, cy));
}
// INVARIANT: a cluster always has ≥1 shape pin — pin 0 is its PORT: the badge rides
// above it and bundled edges trunk through it. Born facing the autopoet.
function ensurePort(c, mpts) {
  if ((c.pins || []).length || !mpts.length) return;
  const [cx, cy] = memberCentroid(mpts);
  const poly = hullOffsetPts(mpts, 44);
  const self = worldData && worldData.nodes.find(n => n.id === "self");
  const at = self && self.x != null
    ? nearestOnPoly([self.x, self.y], poly).pt
    : poly.reduce((a, p) => p[1] < a[1] ? p : a, poly[0]);
  c.pins = [{ dx: +(at[0] - cx).toFixed(1), dy: +(at[1] - cy).toFixed(1) }];
  saveClusters();
}
function togglePinWorld(c, idx) {
  const mpts = clusterMembers(c, worldData.nodes)
    .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
  if (!mpts.length) return;
  const [cx, cy] = memberCentroid(mpts);
  const p = c.pins[idx];
  c.pins[idx] = p.world
    ? { dx: +(p.x - cx).toFixed(1), dy: +(p.y - cy).toFixed(1) }
    : { x: +(cx + p.dx).toFixed(1), y: +(cy + p.dy).toFixed(1), world: true };
  clusterChanged();
}
function pinCtx(e, c, idx) {
  const p = c.pins[idx];
  const items = [
    { icon: "map-pin", label: p.world ? "release — ride the cluster" : "pin to world space",
      fn: () => togglePinWorld(c, idx) }
  ];
  // the last pin is the cluster's port — it can move, never vanish
  if (c.pins.length > 1)
    items.push("-", { icon: "trash-2", label: "remove pin", danger: true,
      fn: () => { c.pins.splice(idx, 1); clusterChanged(); } });
  showCtx(e.clientX, e.clientY, items);
}
// pinning the badge ANCHORS THE WHOLE CLUSTER in world space — as if you held it
// there by the handle. The badge freezes at its spot, an anchor spring holds the
// members' centroid in place (they stay locally dynamic), and dragging the pinned
// badge tows cluster + anchor together. Shape points stay relative to the cluster.
function toggleBadgeWorld(c, atX, atY) {
  if (c.badge && c.badge.world) { c.badge = null; }
  else {
    const mpts = clusterMembers(c, worldData.nodes)
      .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
    if (!mpts.length) return;
    const [cx, cy] = memberCentroid(mpts);
    c.badge = { x: +atX.toFixed(1), y: +atY.toFixed(1), cx: +cx.toFixed(1), cy: +cy.toFixed(1), world: true };
  }
  clusterChanged();
}
function badgeCtx(e, c, bx, by) {
  showCtx(e.clientX, e.clientY, [
    { icon: "map-pin", label: c.badge && c.badge.world ? "release anchor — float free" : "anchor cluster in world space",
      fn: () => toggleBadgeWorld(c, bx, by) },
    { icon: "info", label: "details", fn: () => showClusterPanel(c) },
    { icon: c.collapsed ? "maximize-2" : "minimize-2", label: c.collapsed ? "expand" : "collapse to one node",
      fn: () => { c.collapsed = !c.collapsed; saveClusters(); draw(); } },
    "-",
    { icon: "trash-2", label: "dissolve cluster", danger: true, fn: () => removeCluster(c.id) }
  ]);
}
function nearestOnPoly(p, poly) {
  let best = { d: Infinity, pt: poly[0] };
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [x1, y1] = poly[j], [x2, y2] = poly[i];
    const L2 = (x2 - x1) ** 2 + (y2 - y1) ** 2 || 1;
    const t = Math.max(0, Math.min(1, ((p[0] - x1) * (x2 - x1) + (p[1] - y1) * (y2 - y1)) / L2));
    const q = [x1 + t * (x2 - x1), y1 + t * (y2 - y1)];
    const d = Math.hypot(p[0] - q[0], p[1] - q[1]);
    if (d < best.d) best = { d, pt: q };
  }
  return best;
}
// the padded outline polygon: bbox corners for 1-2 points, radially-offset hull above
function hullOffsetPts(pts, pad) {
  if (pts.length < 3) {
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
    const x0 = Math.min(...xs) - pad, x1 = Math.max(...xs) + pad;
    const y0 = Math.min(...ys) - pad, y1 = Math.max(...ys) + pad;
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
  }
  const hull = d3.polygonHull(pts);
  const [cx, cy] = d3.polygonCentroid(hull);
  return hull.map(([x, y]) => {
    const dx = x - cx, dy = y - cy, L = Math.hypot(dx, dy) || 1;
    return [x + dx / L * pad, y + dy / L * pad];
  });
}
// one uniform colour wash + subtle outline: a real rounded offset polygon, no donut
function hullPath(pts, pad) {
  const off = hullOffsetPts(pts, pad);
  const n = off.length;
  let d = "";
  for (let i = 0; i < n; i++) {
    const p0 = off[(i + n - 1) % n], p1 = off[i], p2 = off[(i + 1) % n];
    const l1 = Math.hypot(p1[0] - p0[0], p1[1] - p0[1]) || 1, l2 = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) || 1;
    const r = Math.min(22, l1 / 2, l2 / 2);
    const a = [p1[0] - (p1[0] - p0[0]) / l1 * r, p1[1] - (p1[1] - p0[1]) / l1 * r];
    const b = [p1[0] + (p2[0] - p1[0]) / l2 * r, p1[1] + (p2[1] - p1[1]) / l2 * r];
    d += (i ? "L" : "M") + a.map(v => v.toFixed(1)) + " Q" + p1.map(v => v.toFixed(1)) + " " + b.map(v => v.toFixed(1)) + " ";
  }
  return d + "Z";
}
// click near the membrane's EDGE plants a shape pin exactly ON the stroke (pure
// sculpting, no meaning); click the interior opens the cluster panel.
// The hover GHOST is the contract: if it's showing for this cluster, the click
// plants at ITS spot — re-deriving the threshold here could disagree with what
// the human was just shown (the old "preview shows, click doesn't take" bug).
let pinSpot = null;   // { cid, pt } while the preview ghost is visible
function hullClick(e, c, pts) {
  const p = d3.pointer(e, g.node());
  const k = d3.zoomTransform(svg.node()).k || 1;
  const near = nearestOnPoly(p, hullOffsetPts(pts, 44));
  const spot = pinSpot && pinSpot.cid === c.id ? pinSpot.pt
             : near.d < 20 / k ? near.pt : null;
  if (spot) {
    const mpts = clusterMembers(c, worldData.nodes)
      .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
    if (!mpts.length) return;
    const [cx, cy] = memberCentroid(mpts);
    (c.pins = c.pins || []).push({ dx: +(spot[0] - cx).toFixed(1), dy: +(spot[1] - cy).toFixed(1) });
    clusterChanged();
    toast("shape pin added — drag to sculpt, right-click to remove");
  } else showClusterPanel(c);
}
let pinDrag = null;
function beginPinDrag(e, c, idx) {
  e.preventDefault(); e.stopPropagation();
  pinDrag = { c, idx, start: d3.pointer(e, g.node()), orig: { ...c.pins[idx] } };
  if (sim) sim.alphaTarget(0.05).restart();   // keep hulls repainting while sculpting
}
addEventListener("mousemove", e => {
  if (!pinDrag) return;
  const p = d3.pointer(e, g.node());
  const dx = p[0] - pinDrag.start[0], dy = p[1] - pinDrag.start[1];
  pinDrag.c.pins[pinDrag.idx] = pinDrag.orig.world
    ? { x: pinDrag.orig.x + dx, y: pinDrag.orig.y + dy, world: true }
    : { dx: pinDrag.orig.dx + dx, dy: pinDrag.orig.dy + dy };
});
addEventListener("mouseup", () => {
  if (!pinDrag) return;
  if (sim) sim.alphaTarget(0);
  saveClusters();
  pinDrag = null;
});

// the MEMBRANE: slow drags rearrange members INSIDE the cluster freely; breaking out
// takes active effort — a decisive pull (speed × stretch) or dragging genuinely far.
// Fires live mid-drag, so the hull visibly lets go while you're still holding.
function maybeElasticExit(d) {
  if (!d || d.x == null) return false;
  for (const c of clusters) {
    if (c.rule || c.collapsed || !(c.members || []).includes(d.id)) continue;
    const others = clusterMembers(c, worldData.nodes).filter(id => id !== d.id)
      .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null);
    if (!others.length) continue;
    const cx = d3.mean(others, n => n.x), cy = d3.mean(others, n => n.y);
    if (d._justJoined === c.id) {
      // still settling inside — but crossing back OUT of the hull re-arms the membrane,
      // so one held gesture can take a node in and out repeatedly
      const mpts = others.map(n => [n.x, n.y]);
      if (inPoly([d.x, d.y], hullOffsetPts(withPins(c, mpts), 44))) continue;
      d._justJoined = null;
    }
    const dist = Math.hypot(d.x - cx, d.y - cy);
    const v = d._dv || 0;   // smoothed drag speed (px/ms)
    if (dist > 360 || (dist > 210 && v > 1.0)) {
      c.members = c.members.filter(i => i !== d.id);
      if (c.shape) delete c.shape[d.id];
      d._justLeft = c.id;   // don't get re-swallowed while still dragging nearby
      toast(`popped out of ${c.name}`);
      clusterChanged();
      return true;
    }
  }
  return false;
}
// membrane ENTRY is easy and immediate: while you're actively dragging a node, the
// instant it crosses the hull border it belongs — no release needed. (Passive
// overlap never captures; the wall force below keeps outsiders from drifting in.)
function maybeJoinCluster(d) {
  if (!d || d.id === "self" || d.type === "cluster" || d.x == null) return;
  for (const c of clusters) {
    if (c.collapsed || c.rule || (c.members || []).includes(d.id)) continue;
    const mpts = clusterMembers(c, worldData.nodes)
      .map(id => worldData.nodes.find(n => n.id === id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
    if (!mpts.length) continue;
    const inside = inPoly([d.x, d.y], hullOffsetPts(withPins(c, mpts), 44));
    if (d._justLeft === c.id) {
      if (inside) continue;      // still within the old hull — don't re-swallow
      d._justLeft = null;        // fully clear of it — the NEXT crossing joins again
      continue;
    }
    if (!inside) continue;
    (c.members = c.members || []).push(d.id);
    d._justJoined = c.id;   // hysteresis: entering doesn't instantly bounce back out
    toast(`joined ${c.name}`);
    clusterChanged();
    return;
  }
}
function clusterCtx(e, c) {
  if (!c) return;
  showCtx(e.clientX, e.clientY, [
    { icon: "info", label: "details", fn: () => showClusterPanel(c) },
    { icon: c.collapsed ? "maximize-2" : "minimize-2", label: c.collapsed ? "expand" : "collapse to one node",
      fn: () => { c.collapsed = !c.collapsed; saveClusters(); draw(); } },
    "-",
    { icon: "trash-2", label: "dissolve cluster", danger: true, fn: () => removeCluster(c.id) }
  ]);
}
// the cluster's context lives ON the cluster (name/tags/note), not the filesystem
function showClusterPanel(c) {
  if (!c) return;
  const n = c.collapsed
    ? (worldData.nodes.find(x => x.clusterId === c.id) || {}).count || 0
    : clusterMembers(c, worldData.nodes).length;
  panel.innerHTML = `
    <h3>${esc(c.name)}</h3>
    <span class="tag" style="background:${c.color}">cluster · ${n} node${n === 1 ? "" : "s"}${c.rule ? " · rule: " + esc(c.rule.kind === "type" ? "type:" + c.rule.value : c.rule.value) : ""}</span>
    <div class="clrow"><input id="cl-name" value="${esc(c.name)}" spellcheck="false" title="name"></div>
    <div class="clrow"><input id="cl-tags" value="${esc((c.tags || []).join(", "))}" placeholder="tags, comma separated…" spellcheck="false"></div>
    <div class="clrow"><textarea id="cl-note" rows="3" placeholder="context for this group…" spellcheck="false">${esc(c.note || "")}</textarea></div>
    <div class="clpal">${CLPAL.map(col =>
      `<button class="swb ${col === c.color ? "sel" : ""}" data-c="${col}" style="background:${col}"></button>`).join("")}</div>
    <div class="clacts">
      <button id="cl-collapse">${c.collapsed ? "expand" : "collapse"}</button>
      <button id="cl-dissolve" class="no">dissolve</button>
    </div>`;
  panel.style.display = "block";
  const commit = () => {
    c.name = document.getElementById("cl-name").value.trim() || c.name;
    c.tags = document.getElementById("cl-tags").value.split(",").map(s => s.trim()).filter(Boolean);
    c.note = document.getElementById("cl-note").value;
    saveClusters();
  };
  ["cl-name", "cl-tags", "cl-note"].forEach(id => document.getElementById(id).onchange = () => { commit(); clusterChanged(); });
  panel.querySelectorAll(".swb").forEach(b => b.onclick = () => {
    c.color = b.dataset.c; commit(); clusterChanged();
    panel.querySelectorAll(".swb").forEach(x => x.classList.toggle("sel", x === b));
  });
  document.getElementById("cl-collapse").onclick = () => { commit(); c.collapsed = !c.collapsed; saveClusters(); panel.style.display = "none"; draw(); };
  document.getElementById("cl-dissolve").onclick = () => { removeCluster(c.id); panel.style.display = "none"; };
}
// in-theme one-field prompt (same frame the rename dialog uses)
function askText(title, value, placeholder) {
  return new Promise(resolve => {
    openModalRaw(`<h3>${esc(title)}</h3>
      <input id="modalname" value="${esc(value || "")}" placeholder="${esc(placeholder || "")}" spellcheck="false">
      <div class="acts"><button id="modalcancel">cancel</button>
      <button class="go" id="modalgo">create</button></div>`);
    const inp = document.getElementById("modalname");
    setTimeout(() => inp.focus(), 60);
    const done = v => { closeModal(); resolve(v); };
    document.getElementById("modalcancel").onclick = () => done(null);
    document.getElementById("modalgo").onclick = () => done(inp.value.trim() || null);
    inp.onkeydown = e => {
      if (e.key === "Enter") done(inp.value.trim() || null);
      if (e.key === "Escape") done(null);
    };
  });
}
document.getElementById("cb-filter").onclick = e => { e.stopPropagation(); collapseSearch(); openFilterPop(); };
addEventListener("mousedown", e => {
  const p = document.getElementById("filterpop");
  if (p.classList.contains("on") && !p.contains(e.target) && !e.target.closest("#cb-filter")) closeFilterPop();
});
document.getElementById("searchin").addEventListener("input", e => {
  const q = e.target.value.trim().toLowerCase();
  const res = document.getElementById("searchres");
  searchpop.classList.toggle("on", !!q);
  if (!q) { res.innerHTML = ""; clearSearchDim(); return; }
  const hits = worldData.nodes.filter(n =>
    (n.label + " " + (n.detail || "")).toLowerCase().includes(q)).slice(0, 12);
  const ids = new Set(hits.map(h => h.id));
  // dim non-matches on the canvas
  g.selectAll("g").filter(function () { return this.__data__ && this.__data__.id; })
    .attr("opacity", d => ids.has(d.id) ? 1 : 0.15);
  res.innerHTML = hits.map(h =>
    `<div class="it" data-id="${esc(h.id)}"><span class="sw" style="background:${color(h)}"></span>${esc(h.label)}</div>`).join("");
  res.querySelectorAll(".it").forEach(el => el.onclick = () => zoomTo(el.dataset.id));
});
function zoomTo(id, panel = true) {
  const n = worldData.nodes.find(n => n.id === id);
  if (!n) return;
  // a hidden-type node has no sim position — open its panel instead of flying
  if (n.x == null) { if (panel) showPanel(n); return; }
  const stage = document.getElementById("stage");
  const t = d3.zoomIdentity.translate(stage.clientWidth / 2 - n.x * 1.25, stage.clientHeight / 2 - n.y * 1.25).scale(1.25);
  svg.transition().duration(550).call(zoomB.transform, t);
  if (panel) showPanel(n);
}

function renderNotifications() {
  const pend = worldData.nodes.filter(n => n.type === "proposal" && n.status === "pending");
  const bdg = document.getElementById("bellbdg");
  bdg.style.display = pend.length ? "flex" : "none";
  bdg.textContent = pend.length;
  const body = document.getElementById("notifbody");
  body.innerHTML =
    (pend.length ? pend.map(p => {
      const id = p.id.slice(5);
      return `<div class="card"><div class="t">${esc(p.label)}</div>
        <div class="d">${esc((p.detail || "").slice(0, 160))}</div>
        <button class="ok" onclick="act('${id}','accept')">accept</button>
        <button class="no" onclick="rejectWithReason('${id}')">reject</button></div>`;
    }).join("") : `<div class="ev">nothing pending — proposals land here for review</div>`)
    + recentEvents.map(t => `<div class="ev">${esc(t)}</div>`).join("");
}
const recentEvents = [];

