// ══ THE FACE — one reusable component (graph self-node, onboarding, anywhere) ══
// createFace(mount, opts) mounts the /avatar SVG and wires blink + cursor-parallax +
// hover (hopeful↔neutral) + a playful click reaction (squint + zigzag/confused mouth).
// opts: idPrefix ("" = primary, keeps #ap-* for voice's setMouth; scoped otherwise),
// svgAttrs (x/y/width/height for an SVG-<g> mount; defaults to 100% for an HTML mount),
// hoverTarget / clickTarget (default the svg itself).
let MOUTHS = {}, _faceSvgText = null;
fetch("/avatar/mouths.json").then(r => r.json()).then(m => MOUTHS = m);
function setMouth(mood) {   // drives the PRIMARY (graph) face — voice mouth-sync uses this
  const g = document.getElementById("ap-mouth");
  if (g && MOUTHS[mood]) g.innerHTML = MOUTHS[mood];
}
async function ensureFaceAssets() {
  if (!_faceSvgText) _faceSvgText = await (await fetch("/avatar")).text();
  if (!Object.keys(MOUTHS).length) MOUTHS = await (await fetch("/avatar/mouths.json")).json();
}
async function createFace(mount, opts = {}) {
  await ensureFaceAssets();
  const p = opts.idPrefix || "";
  const doc = new DOMParser().parseFromString(_faceSvgText.replace(/ap-/g, p + "ap-"), "image/svg+xml");
  const svg = document.importNode(doc.documentElement, true);
  if (opts.svgAttrs) for (const [k, v] of Object.entries(opts.svgAttrs)) svg.setAttribute(k, v);
  else { svg.setAttribute("width", "100%"); svg.setAttribute("height", "100%"); }
  svg.id = p + "ap-svg";
  mount.appendChild(svg);
  const el = s => document.getElementById(p + "ap-" + s);
  const setM = mood => { const m = el("mouth"); if (m && MOUTHS[mood]) m.innerHTML = MOUTHS[mood]; };
  let squint = false;
  // eyes are a SHAPE SWAP, nothing else — two baked groups (open / closed-dash),
  // toggled by the display attribute. No transforms, no scaling, no animation:
  // WebKit (the desktop shell) ghosts transformed SVG internals; a swap can't.
  function setEyes(open) {
    const o = el("eyes-open"), c = el("eyes-closed");
    if (o) o.setAttribute("display", open ? "inline" : "none");
    if (c) c.setAttribute("display", open ? "none" : "inline");
  }
  // blink
  (function blink() {
    if (el("eyes")) { setEyes(false); setTimeout(() => setEyes(!squint), 110); }
    setTimeout(blink, 3000 + Math.random() * 3000);
  })();
  // cursor parallax
  let tx = 0, ty = 0, want = { x: 0, y: 0 }, raf = null;
  const clamp = v => Math.max(-1, Math.min(1, v));
  addEventListener("mousemove", e => {
    const r = svg.getBoundingClientRect(); if (!r.width) return;
    want = { x: clamp((e.clientX - (r.left + r.width / 2)) / (r.width * 0.9)),
             y: clamp((e.clientY - (r.top + r.height / 2)) / (r.height * 0.9)) };
    if (!raf) raf = requestAnimationFrame(apply);
  }, { passive: true });
  function apply() {
    raf = null;
    // primary face: during a call VoiceStage owns gaze/attention — stand down
    if (!p && typeof selfCube !== "undefined" && selfCube && selfCube.dataset.free === "1") return;
    const face = el("face"), eyesPx = el("eyes-px"); if (!face || !eyesPx) return;
    tx += (want.x - tx) * 0.35; ty += (want.y - ty) * 0.35;
    face.setAttribute("transform", `translate(${(tx*2.2).toFixed(2)} ${(ty*2.2).toFixed(2)}) skewX(${(-tx*1.8).toFixed(2)}) skewY(${(ty*1.0).toFixed(2)})`);
    eyesPx.setAttribute("transform", `translate(${(tx*0.8).toFixed(2)} ${(ty*0.8).toFixed(2)})`);
    if (Math.abs(want.x - tx) > 0.005 || Math.abs(want.y - ty) > 0.005) raf = requestAnimationFrame(apply);
  }
  // hover: hopeful ↔ neutral (as in the original)
  const hov = opts.hoverTarget || svg;
  const freed = () => !p && typeof selfCube !== "undefined" && selfCube && selfCube.dataset.free === "1";
  hov.addEventListener("mouseenter", () => { if (!freed()) setM("hopeful"); });
  hov.addEventListener("mouseleave", () => { if (!squint && !freed()) setM("neutral"); });
  // click: a quick "click-in" blip — a couple frames of squint + zigzag (confused)
  // mouth to acknowledge the click, then straight back (not held)
  const clk = opts.clickTarget || svg;
  clk.addEventListener("click", () => {
    if (freed()) return;   // no click blips mid-call
    squint = true;
    setEyes(false);   // the squint IS the closed-dash shape — swap, no scaling
    setM("confused");
    clearTimeout(svg._react);
    svg._react = setTimeout(() => { squint = false; setEyes(true); setM("neutral"); }, 160);
  });
  return { svg, setMouth: setM, el };
}

// ── the self node's body: the cube avatar. ONE persistent element (survives
// draw() redraws); the svg self group stays as the physics/zoom anchor. ──
let selfCube = null, selfCubeInner = null;
async function ensureSelfCube() {
  // SINGLE-FLIGHT: draw() re-runs on every data refresh, and the old guard
  // only landed after an await — overlapping draws each hatched a cube and
  // the orphans piled up unsynced at the canvas origin. One promise, ever.
  if (ensureSelfCube._p) return ensureSelfCube._p;
  ensureSelfCube._p = buildSelfCube();
  return ensureSelfCube._p;
}
async function buildSelfCube() {
  // heal any strays from a previous racy session
  document.querySelectorAll("#self-cube").forEach(el => el.remove());
  selfCube = null; selfCubeInner = null;
  const sc = document.createElement("div");
  sc.id = "self-cube";
  sc.innerHTML = '<div class="sc-cube"><div class="sc-layer sc-face"></div></div>';
  document.getElementById("stage").appendChild(sc);
  const cube = sc.firstChild;
  const face = cube.firstChild;
  // the WebGL body — wait for the module, then mount into the container
  for (let i = 0; i < 200 && !window.Avatar3D; i++) await new Promise(r => setTimeout(r, 50));
  if (window.Avatar3D) sc._avatar3d = Avatar3D.mount(sc, cube);
  // the SAME primary face (#ap-* ids): mouths.json, voice visemes, hover and
  // click reactions all keep working exactly as before — new body, same soul
  await createFace(face, { idPrefix: "", hoverTarget: cube, clickTarget: cube });
  // clicking the head opens the self panel (as the old node click did)
  cube.addEventListener("click", () => {
    if (sc.dataset.free === "1") return;   // not during a call
    const n = worldData?.nodes?.find(n => n.id === "self");
    if (n) showPanel(n);
  });
  // idle life: breathing + a light whole-body cursor tilt
  let bt = 0;
  setInterval(() => { bt += 0.09;
    cube.style.setProperty("--br", (Math.sin(bt * 2 * Math.PI / 4) * 0.7).toFixed(2) + "deg"); }, 90);
  addEventListener("mousemove", e => {
    if (sc.dataset.free === "1") return;   // VoiceStage owns gaze during calls
    const r = sc.getBoundingClientRect(); if (!r.width) return;
    const tx = Math.max(-1, Math.min(1, (e.clientX - (r.left + r.width / 2)) / (innerWidth * .5)));
    const ty = Math.max(-1, Math.min(1, (e.clientY - (r.top + r.height / 2)) / (innerHeight * .5)));
    cube.style.setProperty("--ry", (tx * 8).toFixed(2) + "deg");
    cube.style.setProperty("--rx", (-ty * 8).toFixed(2) + "deg");
  }, { passive: true });
  selfCube = sc; selfCubeInner = cube;
}
// world coords → screen: the cube rides the node through every tick and zoom
let charEditMode = false;   // set while the "customize autopoet" editor is open
function syncSelfCube() {
  if (!selfCube || selfCube.dataset.free === "1" || charEditMode) return;
  const n = worldData?.nodes?.find(n => n.id === "self");
  if (!n || n.x == null) return;
  const t = d3.zoomTransform(svg.node());
  const px = t.applyX(n.x), py = t.applyY(n.y);
  const s = (96 / 132) * t.k;   // renders at the old face's 96px footprint
  selfCube.style.transform = `translate(${px - 66}px, ${py - 66}px) scale(${s.toFixed(4)})`;
}

let sim;
async function draw() {
  const stage = document.getElementById("stage");
  const W = stage.clientWidth, H = stage.clientHeight;
  svg.attr("width", W).attr("height", H);
  let data;
  try { data = await (await fetch("/graph.json")).json(); }
  catch (err) { return fatal("graph.json fetch failed: " + err); }
  if (!data.nodes || !data.nodes.length) return fatal("graph.json returned no nodes");
  data = applyClusterTransform(data);
  // first load with no saved choice: adopt the server's default_hidden (I3)
  if (!hiddenAdopted) {
    (data.default_hidden || []).forEach(t => hiddenTypes.add(t));
    hiddenAdopted = true;
    saveHidden();
  }
  worldData = data;
  // GENESIS I3: hidden types leave the SIMULATION entirely — plumbing takes no
  // layout space. worldData keeps the full set (search list, filter counts,
  // notifications); un-hiding a type re-draws it into the world.
  {
    const simNodes = data.nodes.filter(n => !hiddenTypes.has(n.type));
    const simIds = new Set(simNodes.map(n => n.id));
    const simLinks = (data.links || []).filter(l => {
      const s = l.source && l.source.id !== undefined ? l.source.id : l.source;
      const t = l.target && l.target.id !== undefined ? l.target.id : l.target;
      return simIds.has(s) && simIds.has(t);
    });
    data = { ...data, nodes: simNodes, links: simLinks };
  }
  renderNotifications();
  g.selectAll("*").remove();
  paper(g);
  const hullLayer = g.append("g");   // cluster hulls sit under links + nodes
  window.vsHullLayer = hullLayer;    // VoiceStage fades hulls with the world
  let badgeLayer = null;             // …but their badges ride ABOVE everything (assigned after nodes)
  const byId = new Map(data.nodes.map(n => [n.id, n]));
  // clustered nodes get extra elbow room so their labels never collide inside the hull
  const clustered = new Set();
  for (const c of clusters) if (!c.collapsed)
    for (const id of clusterMembers(c, data.nodes)) clustered.add(id);

  // restore the human's saved arrangement; brand-new nodes start near the centre
  let restored = 0;
  for (const n of data.nodes) {
    const p = forcePos[n.id];
    if (p) { n.x = p.x; n.y = p.y; restored++; }
    else if (n.id !== "self") { n.x = W / 2 + (Math.random() - .5) * 220; n.y = H / 2 + (Math.random() - .5) * 220; }
  }

  sim = d3.forceSimulation(data.nodes)
    .force("link", d3.forceLink(data.links).id(d => d.id)
      .distance(l => l.kind === "ref" ? 90 : 150).strength(l => l.kind === "ref" ? 0.5 : 0.08))
    // repulsion is LOCAL (distanceMax) — gravity that shoves neighbors apart must
    // not keep flinging distant strays to the edge of the world
    .force("charge", d3.forceManyBody().strength(-320).distanceMax(420))
    .force("center", d3.forceCenter(W / 2, H / 2))
    // the autopoet holds the strongest field on the canvas — nothing crowds it
    .force("collide", d3.forceCollide(d => d.id === "self" ? 110 : radius(d) + (clustered.has(d.id) ? 36 : 14)))
    // the membrane is a HARD WALL for outsiders: any non-member that drifts inside a
    // hull is shoved back out (actively-dragged nodes — fx pinned — pass through)
    .force("membrane", alpha => {
      for (const c of clusters) {
        if (c.collapsed) continue;
        const mset = new Set(clusterMembers(c, data.nodes));
        const mpts = [...mset].map(id => byId.get(id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
        if (!mpts.length) continue;
        const poly = hullOffsetPts(withPins(c, mpts), 52);
        const [cx, cy] = memberCentroid(mpts);
        for (const n of data.nodes) {
          if (n.fx != null || n.x == null || mset.has(n.id)) continue;
          if (!inPoly([n.x, n.y], poly)) continue;
          const dx = n.x - cx, dy = n.y - cy, L = Math.hypot(dx, dy) || 1;
          n.vx += dx / L * (12 * alpha + 0.5);   // strong outward shove…
          n.x += dx / L * 2.4; n.y += dy / L * 2.4;   // …plus direct correction: a wall, not a spring
        }
        // the autopoet's field outranks membranes: a hull encroaching on it shifts
        // the WHOLE cluster away (uniform — shape preserved), overriding the anchor
        const selfN = byId.get("self");
        if (selfN && selfN.x != null) {
          const FIELD = 130;
          const near = nearestOnPoly([selfN.x, selfN.y], poly);
          const d0 = inPoly([selfN.x, selfN.y], poly) ? -near.d : near.d;
          if (d0 < FIELD) {
            let ax = cx - selfN.x, ay = cy - selfN.y;
            const L = Math.hypot(ax, ay) || 1;
            const push = (FIELD - d0) * 0.12 * (alpha + 0.05);
            for (const id of mset) {
              const n = byId.get(id);
              if (n && n.fx == null) { n.vx += ax / L * push; n.vy += ay / L * push; }
            }
          }
        }
      }
    })
    // an ANCHORED cluster (badge pinned to world space) is held in place: a uniform
    // spring keeps the members' centroid at the anchor while they stay locally dynamic
    .force("anchor", alpha => {
      for (const c of clusters) {
        if (c.collapsed || !(c.badge && c.badge.world)) continue;
        const ms = clusterMembers(c, data.nodes).map(id => byId.get(id)).filter(n => n && n.x != null);
        if (!ms.length) continue;
        const cx = d3.mean(ms, n => n.x), cy = d3.mean(ms, n => n.y);
        const kx = (c.badge.cx - cx) * alpha * 0.55, ky = (c.badge.cy - cy) * alpha * 0.55;
        for (const n of ms) { n.vx += kx; n.vy += ky; }
      }
    })
    // cluster members spring back to their REMEMBERED arrangement (centroid + each
    // member's stored offset) — the group translates freely but keeps its shape
    .force("cluster", alpha => {
      for (const c of clusters) {
        if (c.collapsed) continue;
        const ms = clusterMembers(c, data.nodes).map(id => byId.get(id)).filter(n => n && n.x != null);
        if (ms.length < 2) continue;
        const cx = d3.mean(ms, n => n.x), cy = d3.mean(ms, n => n.y);
        for (const n of ms) {
          const rel = c.shape && c.shape[n.id];
          const tx = rel ? cx + rel.x : cx, ty = rel ? cy + rel.y : cy;
          const k = rel ? 0.3 : 0.16;
          n.vx += (tx - n.x) * alpha * k; n.vy += (ty - n.y) * alpha * k;
        }
      }
    });
  // a mostly-remembered layout settles in place instead of re-exploding
  if (restored >= data.nodes.length - 2) sim.alpha(0.08);
  sim.on("end.persist", () => { persistForcePos(); captureClusterShapes(); });

  function drawHulls() {
    hullLayer.selectAll("*").remove();
    if (badgeLayer) badgeLayer.selectAll("*").remove();
    for (const c of clusters) {
      if (c.collapsed) continue;
      const mpts = clusterMembers(c, data.nodes).map(id => byId.get(id))
        .filter(n => n && n.x != null).map(n => [n.x, n.y]);
      if (!mpts.length) continue;
      ensurePort(c, mpts);   // every cluster carries at least ONE shape pin — its port
      const pts = withPins(c, mpts);
      const gp = hullLayer.append("g").style("cursor", "pointer")
        .on("click", e => hullClick(e, c, pts))
        .on("contextmenu", e => { e.preventDefault(); clusterCtx(e, c); })
        // hovering the membrane edge previews the pin you'd plant there. The band is
        // SCREEN-space (÷ zoom) so it feels identical at every zoom level, and the
        // previewed spot is recorded — the click plants exactly what the ghost shows.
        .on("mousemove", e => {
          const p = d3.pointer(e, g.node());
          const k = d3.zoomTransform(svg.node()).k || 1;
          const near = nearestOnPoly(p, hullOffsetPts(pts, 44));
          if (near.d < 20 / k && pinPreview) {
            pinSpot = { cid: c.id, pt: near.pt };
            pinPreview.attr("cx", near.pt[0]).attr("cy", near.pt[1]).attr("stroke", c.color).style("display", null);
          } else { if (pinSpot && pinSpot.cid === c.id) pinSpot = null; if (pinPreview) pinPreview.style("display", "none"); }
        })
        .on("mouseleave", () => { pinSpot = null; pinPreview && pinPreview.style("display", "none"); });
      gp.append("path").attr("d", hullPath(pts, 44))
        .attr("fill", c.color).attr("fill-opacity", .065)
        .attr("stroke", c.color).attr("stroke-opacity", .3)
        .attr("stroke-width", 1.4).attr("stroke-linejoin", "round");
      // shape pins: handles sitting ON the membrane — drag to sculpt, right-click for
      // options. Pin 0 is THE PORT (badge home + edge trunk); drawn slightly larger.
      pinPoints(c, mpts).forEach((pp, i) => {
        gp.append("circle").attr("cx", pp[0]).attr("cy", pp[1]).attr("r", i === 0 ? 5.5 : 4.5)
          .attr("class", "cl-pin" + (c.pins[i].world ? " cl-pin-world" : "")).attr("stroke", c.color)
          .on("mousedown", e => beginPinDrag(e, c, i))
          .on("click", e => e.stopPropagation())   // a pin click never falls through to hullClick
          .on("contextmenu", e => { e.preventDefault(); e.stopPropagation(); pinCtx(e, c, i); });
      });
      // badge and port are ONE unit: the badge rides directly above pin 0, always.
      // Drag the port to move where the label sits; anchored badges keep their spot.
      let bp;
      if (c.badge && c.badge.world) bp = [c.badge.x, c.badge.y];
      else {
        const port = pinPoints(c, mpts)[0];
        bp = [port[0], port[1] - 32];
      }
      drawClusterBadge(badgeLayer || gp, c, bp[0], bp[1]);
    }
  }

  const self = data.nodes.find(n => n.id === "self");
  self.fx = W / 2; self.fy = H / 2;

  // links are paths so sibling edges can BUNDLE through a cluster's shape pins
  const link = linkSel = g.append("g").selectAll("path").data(data.links).join("path")
    .attr("fill", "none")
    .attr("stroke", l => l.kind === "ref" ? "var(--edge-ref)" : "var(--edge)")
    .attr("stroke-width", l => l.kind === "ref" ? 1.6 : 1);
  let pinPreview = null;

  const node = nodeSel = g.append("g").selectAll("g").data(data.nodes).join("g")
    .style("cursor", "pointer")
    .call(d3.drag()
      .on("start", (e, d) => { if (!e.active) sim.alphaTarget(0.25).restart();
        d.fx = d.x; d.fy = d.y; d._dv = 0; d._dlast = [e.x, e.y, performance.now()];
        d._justJoined = null; d._justLeft = null; })
      .on("drag", (e, d) => {
        d.fx = e.x; d.fy = e.y;
        const now = performance.now(), [lx, ly, lt] = d._dlast || [e.x, e.y, now];
        d._dv = 0.7 * (d._dv || 0) + 0.3 * (Math.hypot(e.x - lx, e.y - ly) / Math.max(1, now - lt));
        d._dlast = [e.x, e.y, now];
        maybeElasticExit(d);    // membrane break — LIVE, mid-drag
        maybeJoinCluster(d);    // membrane entry — the moment the border is crossed
      })
      .on("end", (e, d) => { if (!e.active) sim.alphaTarget(0);
        if (d.id !== "self") { d.fx = null; d.fy = null; }
        d._justJoined = null; d._justLeft = null;
        captureClusterShapes(); persistForcePos(); }))
    .on("click", (e, d) => d.type === "cluster" ? showClusterPanel(clusterById(d.clusterId)) : showPanel(d))
    .on("contextmenu", (e, d) => {
      e.preventDefault();
      if (d.type === "cluster") return clusterCtx(e, clusterById(d.clusterId));
      const items = [{ icon: "info", label: "details", fn: () => showPanel(d) }];
      for (const c of clusters)
        if (!c.rule && !c.collapsed && (c.members || []).includes(d.id))
          items.push({ icon: "ungroup", label: `remove from # ${c.name}`,
            fn: () => { c.members = c.members.filter(i => i !== d.id); saveClusters(); draw(); } });
      if (d.type === "proposal" && d.status === "pending") {
        const id = d.id.slice(5);
        items.push("-",
          { icon: "check", label: "accept", fn: () => act(id, "accept") },
          { icon: "x", label: "reject…", danger: true, fn: () => rejectWithReason(id) });
      }
      if (d.type === "proposal" && d.status === "accepted") {
        items.push("-", { icon: "undo-2", label: "revert", danger: true, fn: () => act(d.id.slice(5), "revert") });
      }
      if (d.id === "self") {
        items.push("-", { icon: "search", label: "search the world", fn: () => cbSearch.click() });
      }
      showCtx(e.clientX, e.clientY, items);
    });

  node.filter(d => d.id !== "self" && d.type !== "cluster").append("circle")
    .attr("r", radius).attr("fill", d => color(d))
    .attr("fill-opacity", 0.85).attr("stroke", "var(--paper)").attr("stroke-width", 2);

  // a collapsed cluster = one compact squircle carrying its member count
  const clG = node.filter(d => d.type === "cluster");
  clG.append("rect").attr("x", -20).attr("y", -20).attr("width", 40).attr("height", 40).attr("rx", 12)
    .attr("fill", d => color(d)).attr("fill-opacity", 0.9).attr("stroke", "var(--paper)").attr("stroke-width", 2);
  clG.append("text").attr("class", "cl-count").attr("text-anchor", "middle").attr("dy", 4)
    .text(d => d.count);

  // the self node renders as the CUBE overlay (ensureSelfCube); its svg group
  // is only the physics/zoom anchor the cube tracks
  ensureSelfCube();

  node.append("text").attr("class", "lbl").attr("text-anchor", "middle")
    .attr("dy", d => radius(d) + 14)
    .text(d => d.id === "self" ? "" : (d.label.length > 22 ? d.label.slice(0, 21) + "…" : d.label));
  badgeLayer = g.append("g");   // cluster badges: topmost — edges pass BEHIND them
  window.vsBadgeLayer = badgeLayer;   // VoiceStage hooks fade badges with the world

  // edge bundling: sibling links from ONE external node into a cluster share a pin —
  // they merge into a single trunk to the membrane, then disperse to their members.
  // More pins = more trunks (each source group takes its nearest pin); spare pins
  // just shape. Recomputed per tick so trunks track the layout.
  function routeLinks() {
    const memberOf = new Map(), pinPos = new Map();
    for (const c of clusters) {
      if (c.collapsed) continue;
      const ids = clusterMembers(c, data.nodes);
      const mpts = ids.map(id => byId.get(id)).filter(n => n && n.x != null).map(n => [n.x, n.y]);
      if (!mpts.length) continue;
      for (const id of ids) if (!memberOf.has(id)) memberOf.set(id, c);
      if ((c.pins || []).length) pinPos.set(c.id, pinPoints(c, mpts));
    }
    const routeOf = l => {
      const cs = memberOf.get(l.source.id), ct = memberOf.get(l.target.id);
      if (ct && cs !== ct) return { ext: l.source, mem: l.target, cl: ct };
      if (cs && cs !== ct) return { ext: l.target, mem: l.source, cl: cs };
      return null;
    };
    const groups = new Map();
    for (const l of data.links) {
      const r = routeOf(l);
      if (r && pinPos.has(r.cl.id)) {
        const k = r.ext.id + "→" + r.cl.id;
        groups.set(k, (groups.get(k) || 0) + 1);
      }
    }
    link.attr("d", l => {
      const r = routeOf(l);
      if (r && pinPos.has(r.cl.id) && groups.get(r.ext.id + "→" + r.cl.id) >= 2) {
        let best = null, bd = Infinity;
        for (const pp of pinPos.get(r.cl.id)) {
          const dd = Math.hypot(pp[0] - r.ext.x, pp[1] - r.ext.y);
          if (dd < bd) { bd = dd; best = pp; }
        }
        return `M${r.ext.x},${r.ext.y}L${best[0]},${best[1]}L${r.mem.x},${r.mem.y}`;
      }
      return `M${l.source.x},${l.source.y}L${l.target.x},${l.target.y}`;
    });
  }

  sim.on("tick", () => {
    routeLinks();
    node.attr("transform", d => `translate(${d.x},${d.y})`);
    drawHulls();
    syncSelfCube();
  });
  routeLinks(); drawHulls();   // paint immediately too (a fully-restored layout barely ticks)
  // the pin hover-preview ghost rides above everything
  pinPreview = g.append("circle").attr("class", "cl-pin cl-pin-preview").attr("r", 4.5)
    .style("display", "none").style("pointer-events", "none");

  if (!forceZoomed) { restoreZoom(); forceZoomed = true; }
  applyFilter();          // re-apply any active type filter to the fresh selection
  updateSelectionUI();    // dotted highlights survive redraws
}
let forceZoomed = false;


