// ── INTERACTIVE PLAN MODE — Phase 1: canvas + camera (docs/interactive-plan-mode.md) ──
// The onboarding as a living whiteboard: an inset graph-paper canvas, ELK-laid
// free-form nodes/clusters, a floating cube with a pointer beam + speech bubble,
// camera that eases to the active cluster, refocus, and the bottom next/back
// widget. Phase 1 walks a scripted seed sequence (the "here's how this works"
// demo); Phase 2 replaces the script with the brain loop (dynamic coverage).
// Vanilla D3 (already loaded) + elk.bundled.js (lazy-loaded by the host).
window.PlanMode = (() => {

  // ── the seed script (Phase 1 stand-in for the brain) ─────────────────────
  const SEED = [
    { say: "hi. this board is where we design your nexus — together. let me show you how a system takes shape here.",
      add: { nodes: [
        { id: "you", label: "you", type: "person", cluster: "start" },
        { id: "ap", label: "your autopoet", type: "agent", cluster: "start" }],
        edges: [{ from: "you", to: "ap", label: "works with" }] } },
    { say: "everything hangs off a mission. yours goes here — in your words, not mine.",
      add: { nodes: [{ id: "mission", label: "your mission", type: "mission", cluster: "core" }],
        edges: [{ from: "ap", to: "mission", label: "serves" }] } },
    { say: "then who it's for, and what they need…",
      add: { nodes: [
        { id: "aud", label: "audience", type: "people", cluster: "core" },
        { id: "need", label: "their need", type: "insight", cluster: "core" }],
        edges: [{ from: "mission", to: "aud" }, { from: "aud", to: "need", label: "reveals" }] } },
    { say: "…and the things i weave to meet it — call them tools, skills, apps, whatever fits your head. types here are yours, not a form's.",
      add: { nodes: [
        { id: "weave", label: "a weave", type: "toolkit", cluster: "build" },
        { id: "site", label: "a live site", type: "output", cluster: "build" },
        { id: "sched", label: "every morning", type: "trigger", cluster: "build" }],
        edges: [{ from: "ap", to: "weave", label: "builds" }, { from: "weave", to: "site", label: "ships" }, { from: "sched", to: "weave", label: "wakes" }] } },
    { say: "from here i'd start asking YOU questions — one at a time — and this board fills with your real system. that brain lands next. for now: pan, zoom, poke around. refocus brings you back.",
      end: true }
  ];

  // ── state ─────────────────────────────────────────────────────────────────
  let host, opts, svg, world, edgeG, nodeG, hullG, overlay, zoom, elk;
  let nodes = [], edges = [], step = -1, lastFocus = null, cube, bubble, beam, typeTimer;

  const NODE_H = 46;
  const nodeW = (label) => Math.max(96, 13 + label.length * 8.2 + 26);

  // free-form types get stable pastel coats — no taxonomy, just consistency
  const PALETTE = ["#aee5c2", "#a8d4f0", "#f3c5a3", "#f2ddb0", "#d9c5f0", "#f0c5d8", "#c5e8f0", "#d8e8b8"];
  const typeColor = (t) => {
    let h = 0; for (const c of String(t || "")) h = (h * 31 + c.charCodeAt(0)) >>> 0;
    return PALETTE[h % PALETTE.length];
  };

  // ── boot ──────────────────────────────────────────────────────────────────
  function start(el, options) {
    host = el; opts = options || {};
    host.innerHTML = `
      <div class="pm-frame">
        <svg class="pm-canvas"></svg>
        <svg class="pm-overlay"></svg>
        <div class="pm-cube" id="pm-cube"></div>
        <div class="pm-bubble" id="pm-bubble"></div>
        <button class="pm-refocus" id="pm-refocus" title="back to the action">⌖ refocus</button>
        <div class="pm-widget">
          <div class="pm-q" id="pm-q"></div>
          <div class="pm-nav">
            <button id="pm-back" class="pm-btn ghost">← back</button>
            <span class="pm-dots" id="pm-dots"></span>
            <button id="pm-next" class="pm-btn">next →</button>
          </div>
          <button class="pm-classic" id="pm-classic">use classic setup instead</button>
        </div>
      </div>`;

    svg = d3.select(host).select(".pm-canvas");
    overlay = d3.select(host).select(".pm-overlay");
    world = svg.append("g");

    // graph paper — fine + major grid, riding INSIDE the zoomed world
    const defs = svg.append("defs");
    const grid = (id, size, color, w) => {
      defs.append("pattern").attr("id", id).attr("width", size).attr("height", size).attr("patternUnits", "userSpaceOnUse")
        .append("path").attr("d", `M ${size} 0 H 0 V ${size}`).attr("fill", "none").attr("stroke", color).attr("stroke-width", w);
    };
    grid("pm-grid-f", 24, "#eef1f5", 1);
    grid("pm-grid-m", 120, "#e3e8ef", 1);
    world.append("rect").attr("x", -50000).attr("y", -50000).attr("width", 100000).attr("height", 100000).attr("fill", "url(#pm-grid-f)");
    world.append("rect").attr("x", -50000).attr("y", -50000).attr("width", 100000).attr("height", 100000).attr("fill", "url(#pm-grid-m)");

    hullG = world.append("g");
    edgeG = world.append("g");
    nodeG = world.append("g");

    zoom = d3.zoom().scaleExtent([0.25, 2.5]).on("zoom", (e) => {
      world.attr("transform", e.transform);
      placeCube();               // cube/beam/bubble live in screen space
    });
    svg.call(zoom);

    elk = new ELK();

    cube = document.getElementById("pm-cube");
    bubble = document.getElementById("pm-bubble");
    if (opts.createFace) opts.createFace(cube, { idPrefix: "pm" });

    document.getElementById("pm-refocus").onclick = () => lastFocus && focusOn(lastFocus);
    document.getElementById("pm-next").onclick = () => go(step + 1);
    document.getElementById("pm-back").onclick = () => go(step - 1);
    document.getElementById("pm-classic").onclick = () => opts.onQuiz && opts.onQuiz();

    nodes = []; edges = []; step = -1;
    go(0);
  }

  // ── stepper: rebuild graph state 0..n, relayout, animate ──────────────────
  function go(n) {
    if (n < 0 || n >= SEED.length) return;
    const fresh = new Set();
    nodes = []; edges = [];
    for (let i = 0; i <= n; i++) {
      const add = SEED[i].add;
      if (!add) continue;
      for (const nd of add.nodes || []) { nodes.push({ ...nd }); if (i === n) fresh.add(nd.id); }
      for (const ed of add.edges || []) edges.push({ ...ed });
    }
    step = n;
    renderWidget();
    layout().then(() => {
      render(fresh);
      const active = nodes.filter(nd => fresh.has(nd.id));
      const bbox = graphBBox(active.length ? active : nodes);
      lastFocus = bbox;
      focusOn(bbox);
      moveCubeTo(active.length ? active[active.length - 1] : nodes[nodes.length - 1]);
      speak(SEED[n].say);
    });
  }

  // ── ELK layout (stress — free-form, no forced lanes) ──────────────────────
  function layout() {
    const g = {
      id: "root",
      layoutOptions: {
        "elk.algorithm": "stress",
        "elk.stress.desiredEdgeLength": "170",
        "elk.spacing.nodeNode": "60"
      },
      children: nodes.map(n => ({ id: n.id, width: nodeW(n.label), height: NODE_H })),
      edges: edges.map((e, i) => ({ id: "e" + i, sources: [e.from], targets: [e.to] }))
    };
    return elk.layout(g).then(out => {
      const pos = new Map(out.children.map(c => [c.id, c]));
      for (const n of nodes) {
        const p = pos.get(n.id);
        n.x = p.x + p.width / 2; n.y = p.y + p.height / 2; n.w = p.width; n.h = p.height;
      }
    });
  }

  // ── render: hulls, edges, nodes (D3 join, animated) ────────────────────────
  function render(fresh) {
    // cluster hulls — soft rounded plates behind each free-form grouping
    const clusters = d3.group(nodes.filter(n => n.cluster), n => n.cluster);
    hullG.selectAll("rect.pm-hull")
      .data([...clusters], ([k]) => k)
      .join(
        enter => enter.append("rect").attr("class", "pm-hull").attr("rx", 22).style("opacity", 0)
          .call(s => s.transition().duration(500).style("opacity", 1)),
        update => update,
        exit => exit.transition().duration(300).style("opacity", 0).remove()
      )
      .each(function ([, members]) {
        const b = graphBBox(members, 26);
        d3.select(this).transition().duration(600).ease(d3.easeCubicOut)
          .attr("x", b.x).attr("y", b.y).attr("width", b.w).attr("height", b.h);
      });

    const key = e => e.from + "→" + e.to;
    const byId = new Map(nodes.map(n => [n.id, n]));
    const path = e => {
      const a = byId.get(e.from), b = byId.get(e.to);
      const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, dx = b.x - a.x, dy = b.y - a.y;
      const off = Math.min(40, Math.hypot(dx, dy) / 5);
      return `M${a.x},${a.y} Q${mx - dy / 8 - off / 8},${my + dx / 8} ${b.x},${b.y}`;
    };

    const eg = edgeG.selectAll("g.pm-edge").data(edges, key)
      .join(enter => {
        const g = enter.append("g").attr("class", "pm-edge").style("opacity", 0);
        g.append("path");
        g.append("text");
        g.transition().delay(250).duration(450).style("opacity", 1);
        return g;
      });
    eg.select("path").transition().duration(600).ease(d3.easeCubicOut).attr("d", path);
    eg.select("text")
      .text(e => e.label || "")
      .transition().duration(600)
      .attr("x", e => (byId.get(e.from).x + byId.get(e.to).x) / 2)
      .attr("y", e => (byId.get(e.from).y + byId.get(e.to).y) / 2 - 7);

    const ng = nodeG.selectAll("g.pm-node").data(nodes, n => n.id)
      .join(enter => {
        const g = enter.append("g").attr("class", "pm-node")
          .attr("transform", n => `translate(${n.x},${n.y}) scale(0.2)`).style("opacity", 0);
        g.append("rect").attr("rx", 13)
          .attr("fill", "#fff").attr("stroke", n => typeColor(n.type)).attr("stroke-width", 2.5);
        g.append("text").attr("class", "pm-label").attr("text-anchor", "middle").attr("dy", 1);
        g.append("text").attr("class", "pm-type").attr("text-anchor", "middle");
        g.transition().duration(550).ease(d3.easeBackOut.overshoot(1.4))
          .style("opacity", 1).attr("transform", n => `translate(${n.x},${n.y}) scale(1)`);
        return g;
      });
    ng.transition().duration(600).ease(d3.easeCubicOut)
      .attr("transform", n => `translate(${n.x},${n.y}) scale(1)`);
    ng.select("rect")
      .attr("x", n => -n.w / 2).attr("y", n => -n.h / 2)
      .attr("width", n => n.w).attr("height", n => n.h)
      .attr("filter", n => fresh && fresh.has(n.id) ? "drop-shadow(0 3px 10px rgba(30,40,60,.18))" : null);
    ng.select("text.pm-label").text(n => n.label).attr("y", 2);
    ng.select("text.pm-type").text(n => n.type || "").attr("y", n => n.h / 2 + 15)
      .attr("fill", n => d3.color(typeColor(n.type)).darker(1.4));
  }

  // ── camera ─────────────────────────────────────────────────────────────────
  function graphBBox(list, pad = 60) {
    const xs = list.flatMap(n => [n.x - n.w / 2, n.x + n.w / 2]);
    const ys = list.flatMap(n => [n.y - n.h / 2, n.y + n.h / 2]);
    const x = Math.min(...xs) - pad, y = Math.min(...ys) - pad;
    return { x, y, w: Math.max(...xs) + pad - x, h: Math.max(...ys) + pad - y };
  }

  function focusOn(b) {
    const vw = host.clientWidth, vh = host.clientHeight - 130; // leave the widget room
    const k = Math.min(1.5, 0.85 * Math.min(vw / b.w, vh / b.h));
    const t = d3.zoomIdentity.translate(vw / 2 - k * (b.x + b.w / 2), vh / 2 - k * (b.y + b.h / 2)).scale(k);
    svg.transition().duration(850).ease(d3.easeCubicInOut).call(zoom.transform, t);
  }

  // ── the cube: float near the action, beam to the newest node, speak ───────
  let cubeTarget = null;
  function moveCubeTo(node) { cubeTarget = node; placeCube(true); }

  function placeCube(animate) {
    if (!cubeTarget) return;
    const t = d3.zoomTransform(svg.node());
    const sx = t.applyX(cubeTarget.x), sy = t.applyY(cubeTarget.y);
    // sit up-left of the node, clamped inside the frame
    const cx = Math.max(18, Math.min(host.clientWidth - 90, sx - 130));
    const cy = Math.max(18, Math.min(host.clientHeight - 210, sy - 110));
    cube.style.transition = animate ? "left .8s cubic-bezier(.4,0,.2,1), top .8s cubic-bezier(.4,0,.2,1)" : "none";
    cube.style.left = cx + "px"; cube.style.top = cy + "px";
    bubble.style.left = (cx + 66) + "px"; bubble.style.top = Math.max(10, cy - 14) + "px";
    // pointer beam, screen space
    overlay.selectAll("*").remove();
    overlay.append("line").attr("class", "pm-beam")
      .attr("x1", cx + 52).attr("y1", cy + 40).attr("x2", sx).attr("y2", sy);
  }

  function speak(text) {
    clearInterval(typeTimer);
    bubble.textContent = ""; bubble.style.opacity = 1;
    let i = 0;
    typeTimer = setInterval(() => {
      bubble.textContent = text.slice(0, ++i);
      if (i >= text.length) clearInterval(typeTimer);
    }, 14);
  }

  // ── the bottom widget ──────────────────────────────────────────────────────
  function renderWidget() {
    const s = SEED[step];
    document.getElementById("pm-q").textContent = s.say;
    document.getElementById("pm-dots").innerHTML =
      SEED.map((_, i) => `<i class="${i === step ? "on" : ""}"></i>`).join("");
    document.getElementById("pm-back").style.visibility = step === 0 ? "hidden" : "visible";
    const next = document.getElementById("pm-next");
    if (s.end) { next.textContent = "continue setup →"; next.onclick = () => opts.onQuiz && opts.onQuiz(); }
    else { next.textContent = "next →"; next.onclick = () => go(step + 1); }
  }

  return { start };
})();
