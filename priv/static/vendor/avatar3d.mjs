// ══ Avatar3D — the cube's body, rendered with real 3D (Three.js/WebGL) ══
//
// CSS 3D could not deliver the toon outline: WebKit refuses filter unions on
// preserve-3d subtrees, and geometry rings only trace flat planes. Here the
// body is an extruded-squircle MESH and the outline is the classic INVERTED
// HULL (a slightly-fattened backface-culled black mesh) — one clean unioned
// silhouette for the body AND the hands, identical in every WebGL engine,
// WKWebView included.
//
// Contract: this module renders INTO the existing #self-cube container and
// READS the CSS variables the app already writes — --rx/--ry/--rz/--nod/--br
// on the .sc-cube element, and --hx/--hy/--hr/--hs/--po + dataset.pose on
// each .vs-hand controller div. The face stays a DOM SVG overlay (all the
// #ap-* mouth/viseme/parallax machinery untouched); we just glue its overlay
// offset to the body's rotation. Ortho camera keeps the brand's flat look.
import * as THREE from "./three.module.min.js";
import { GLTFLoader } from "./GLTFLoader.mjs";

const SIZE = 132;          // cube edge in px == world units
const R = 35;              // squircle corner radius
const INK = 0x121316;
const CANVAS = 340;        // oversized so hands + outline never clip
const OUT = 2.6;           // outline thickness (world units at scale 1)

// ── baked hand assets ──────────────────────────────────────────────────────
// The hands are a real modelled set ("Hands_Cartoon_Collection", cleaned + baked
// by vendor/bake-hands.py — recentered, one uniform scale, welded, gestures named).
// They load by URL exactly like three.js itself, so they stay external through the
// eventual .work migration; only these three constants point at the asset + list.
const HANDS_URL = "/static/vendor/hands.glb";
const HAND_POSES = ["point", "open", "thumb", "fist", "peace", "two", "spread",
                    "rock", "ily", "palm", "three", "five", "relaxed"];
const HAND_OUT = 2.4;      // hand outline thickness ≈ the body's OUT (2.6) so the toon
                           // line weight reads consistently across body and hands. The
                           // baked mesh is subdivided so this thickness stays clean.

function roundedRectShape(w, h, r) {
  const s = new THREE.Shape(), x = -w / 2, y = -h / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.quadraticCurveTo(x + w, y, x + w, y + r);
  s.lineTo(x + w, y + h - r);
  s.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  s.lineTo(x + r, y + h);
  s.quadraticCurveTo(x, y + h, x, y + h - r);
  s.lineTo(x, y + r);
  s.quadraticCurveTo(x, y, x + r, y);
  return s;
}

// theme-aware face colors — read the app's CSS tokens so the cube follows the
// light/dark toggle (body = the face squircle, inverted hull = its toon outline).
const _hexInt = (v, fb) => {
  v = (v || "").trim().replace(/^#/, "");
  if (v.length === 3) v = v.split("").map(c => c + c).join("");
  const n = parseInt(v, 16);
  return (v.length === 6 && !Number.isNaN(n)) ? n : fb;
};
const _cssVar = name => getComputedStyle(document.documentElement).getPropertyValue(name);
const faceBody = () => _hexInt(_cssVar("--face-bg"), 0xffffff);
// the toon outline is the ONLY part that follows the UI theme (black in light,
// white in dark); the body + face features are the character's own, theme-independent.
const faceOutline = () => _hexInt(_cssVar("--face-outline"), INK);

// body finish: a MATTE MATCAP — the cube reads mostly white, the character's
// color pools only in the depth (grazing bevels/edges) and the shaded flank,
// like a soft ceramic. Not a full-body flat color; an accent on the shadow.
const _hexStr = n => "#" + (n & 0xffffff).toString(16).padStart(6, "0");
const _mix = (aHex, bHex, t) => {
  const ar = (aHex >> 16) & 255, ag = (aHex >> 8) & 255, ab = aHex & 255;
  const br = (bHex >> 16) & 255, bg = (bHex >> 8) & 255, bb = bHex & 255;
  const r = Math.round(ar + (br - ar) * t), g = Math.round(ag + (bg - ag) * t), b = Math.round(ab + (bb - ab) * t);
  return "#" + (((r << 16) | (g << 8) | b) >>> 0).toString(16).padStart(6, "0");
};
// paint a matcap sphere in TWO passes:
//   1. color — a bright matte-white core up-left (the key) fading to the accent
//      on the flank (white→color divergence, not a flat body tint).
//   2. shadow — a NEUTRAL dark vignette multiplied over the rim. Multiply leaves
//      the lit core untouched but deepens the edge on EVERY hue — so the white
//      character finally casts a real grey shadow instead of vanishing.
function matcapTexture(hex) {
  const S = 128, cv = document.createElement("canvas");
  cv.width = cv.height = S;
  const g = cv.getContext("2d");

  // pass 1 — white core → accent flank
  g.fillStyle = _hexStr(hex);
  g.fillRect(0, 0, S, S);
  const col = g.createRadialGradient(S * 0.36, S * 0.30, S * 0.03, S * 0.52, S * 0.54, S * 0.82);
  col.addColorStop(0.00, "#ffffff");
  col.addColorStop(0.42, _mix(hex, 0xffffff, 0.90));
  col.addColorStop(0.72, _hexStr(hex));
  col.addColorStop(1.00, _hexStr(hex));
  g.fillStyle = col;
  g.fillRect(0, 0, S, S);

  // pass 2 — neutral depth shadow, multiplied (core stays lit, rim darkens)
  g.globalCompositeOperation = "multiply";
  const sh = g.createRadialGradient(S * 0.40, S * 0.34, S * 0.08, S * 0.54, S * 0.58, S * 0.82);
  sh.addColorStop(0.00, "#ffffff");   // no darkening on the lit core
  sh.addColorStop(0.55, "#eceef1");
  sh.addColorStop(0.82, "#9a9ea6");
  sh.addColorStop(1.00, "#5f636b");   // deep rim → a real cast shadow on any hue
  g.fillStyle = sh;
  g.fillRect(0, 0, S, S);
  g.globalCompositeOperation = "source-over";

  const tx = new THREE.CanvasTexture(cv);
  tx.colorSpace = THREE.SRGBColorSpace;
  return tx;
}
// ── the BLOB wobble ──────────────────────────────────────────────────────
// A vertex displacement injected into every body/outline shader, scaled by a
// per-material uAmp (0 = rigid; the "blob" shape turns it on). It is a PURE
// FUNCTION of the vertex's rest position and a single shared clock — so it is
// bounded for all time and CANNOT accumulate drift over recursive frames, and
// the loop is seamless. Displacement rides the outward direction, so the flat
// front bulges in depth while the DOM face overlay (a separate layer) stays
// perfectly clean — organic body, unbroken character.
const _wobT = { value: 0 };                 // shared clock (seconds), one write/frame
const CHUNK_HEAD = "uniform float uTime; uniform float uAmp;";
const CHUNK_DISP = `
  #include <begin_vertex>
  if (uAmp > 0.0001) {
    float _w = sin(position.x * 0.045 + uTime * 1.10)
             + sin(position.y * 0.050 + uTime * 0.90)
             + sin(position.z * 0.040 + uTime * 1.30);
    transformed += normalize(position + vec3(0.0001)) * (uAmp * _w);
  }`;
function _wobbleShader(m) {
  m.userData.uAmp = { value: 0 };
  m.onBeforeCompile = shader => {
    shader.uniforms.uTime = _wobT;
    shader.uniforms.uAmp = m.userData.uAmp;
    shader.vertexShader = CHUNK_HEAD + "\n" + shader.vertexShader
      .replace("#include <begin_vertex>", CHUNK_DISP);
  };
}
// Tracked so a theme flip / character recolor can re-skin every instance live.
const _bodyMats = new Set(), _outlineMats = new Set();
function bodyMaterial() {
  const m = new THREE.MeshMatcapMaterial({ matcap: matcapTexture(faceBody()) });
  _wobbleShader(m); _bodyMats.add(m); return m;
}
function outlineMaterial() {
  const m = new THREE.MeshBasicMaterial({ color: faceOutline(), side: THREE.BackSide });
  _wobbleShader(m); _outlineMats.add(m); return m;
}
function _reskin() {
  const b = faceBody(), o = faceOutline();
  _bodyMats.forEach(m => { const old = m.matcap; m.matcap = matcapTexture(b); m.needsUpdate = true; if (old && old !== m.matcap) old.dispose(); });
  _outlineMats.forEach(m => m.color.setHex(o));
}
if (typeof window !== "undefined") {
  // theme flip OR AutoPoet character recolor both re-skin every material live
  window.addEventListener("themechange", _reskin);
  window.addEventListener("characterchange", _reskin);
}

// inverted hull: same geometry pushed out along normals by `w` world units.
// ExtrudeGeometry splits normals at every bevel/corner edge (coincident vertices
// pointing different ways), so pushing each along its OWN normal tears the shell
// open — the "breaks" in the outline. Fix: weld coincident vertices to a single
// AVERAGED normal first, so the pushed-out shell stays watertight.
function hullOf(mesh, w) {
  const geo = mesh.geometry.clone();
  const pos = geo.attributes.position, nor = geo.attributes.normal;
  const groups = new Map();
  const key = i => `${pos.getX(i).toFixed(3)}|${pos.getY(i).toFixed(3)}|${pos.getZ(i).toFixed(3)}`;
  for (let i = 0; i < pos.count; i++) {
    const k = key(i);
    let e = groups.get(k);
    if (!e) groups.set(k, e = { x: 0, y: 0, z: 0, idx: [] });
    e.x += nor.getX(i); e.y += nor.getY(i); e.z += nor.getZ(i); e.idx.push(i);
  }
  for (const e of groups.values()) {
    const len = Math.hypot(e.x, e.y, e.z) || 1;
    const nx = e.x / len, ny = e.y / len, nz = e.z / len;
    for (const i of e.idx) {
      pos.setXYZ(i, pos.getX(i) + nx * w, pos.getY(i) + ny * w, pos.getZ(i) + nz * w);
    }
  }
  const hull = new THREE.Mesh(geo, outlineMaterial());
  hull.position.copy(mesh.position);
  hull.rotation.copy(mesh.rotation);
  hull.scale.copy(mesh.scale);
  return hull;
}

function withHull(mesh, w) {
  const g = new THREE.Group();
  g.add(hullOf(mesh, w === undefined ? OUT : w));
  g.add(mesh);
  return g;
}

// shape presets — corner radius + bevel morph the body squircle → round → blocky.
const SHAPES = {
  squircle: { r: 35, bevel: 8 },              // the default soft cube
  round:    { r: 58, bevel: 13 },             // pillowy, near-circular face
  blocky:   { r: 8,  bevel: 3 },              // sharp, minecrafty cube
  blob:     { r: 60, bevel: 16, wobble: 1.7 },// organic goo — round base + live wobble
};
export const currentShape = () => {
  const k = document.documentElement.getAttribute("data-ap-shape") || "squircle";
  return SHAPES[k] ? k : "squircle";
};

// ── the body: extruded squircle with beveled (soft) front/back edges ──
function buildBody(shapeKey) {
  const sh = SHAPES[shapeKey || currentShape()] || SHAPES.squircle;
  const depth = SIZE - 16;
  const geo = new THREE.ExtrudeGeometry(roundedRectShape(SIZE - 12, SIZE - 12, sh.r), {
    depth, bevelEnabled: true, bevelThickness: sh.bevel, bevelSize: Math.min(6, sh.bevel),
    bevelSegments: 4, curveSegments: 10
  });
  geo.translate(0, 0, -depth / 2);            // center on origin
  geo.computeVertexNormals();
  const mesh = new THREE.Mesh(geo, bodyMaterial());
  const grp = withHull(mesh);
  // "blob": arm the wobble on this body's materials (body + its hull) so only
  // the goo shape ripples; every other shape stays rigid (uAmp = 0).
  if (sh.wobble) grp.traverse(o => { if (o.material && o.material.userData.uAmp) o.material.userData.uAmp.value = sh.wobble; });
  return grp;
}

// ── hands: capsule mitts per pose, mirrored for the left ──
function capsule(r, len, x, y, rotZ, sx) {
  const m = new THREE.Mesh(new THREE.CapsuleGeometry(r, len, 6, 14), bodyMaterial());
  m.position.set(x, y, 0);
  m.rotation.z = rotZ || 0;
  if (sx) m.scale.set(sx, 1, 0.7); else m.scale.set(1, 1, 0.7);
  return m;
}
// pose parts in a 30×40-ish local space, origin at the hand's visual center
function posePartsFor(pose) {
  if (pose === "open") return [
    capsule(9.5, 3, 0, -6, 0),                       // palm
    capsule(2.8, 9, -6.2, 8, 0),                     // fingers
    capsule(2.8, 11, 0, 9, 0),
    capsule(2.8, 9, 6.2, 8, 0),
    capsule(3.4, 6, 11.5, -5, 1.1)                   // thumb
  ];
  if (pose === "thumb") return [
    capsule(8.5, 5, 0, -4, 0),                       // fist
    capsule(3.4, 11, 5.5, 8, 0.16)                   // thumb up
  ];
  return [                                           // point (the bean + thumb)
    capsule(7.5, 16, 0, 0, 0),
    capsule(4.2, 5, 8.5, -6, 0.5)
  ];
}
function buildHandPose(pose, mirror) {
  const g = new THREE.Group();
  for (const part of posePartsFor(pose)) {
    part.updateMatrix();
    g.add(hullOf(part, 2.0));
    g.add(part);
  }
  if (mirror) g.scale.x *= -1;
  g.visible = false;
  return g;
}

// ── baked hands (from HANDS_URL) ────────────────────────────────────────────
// A right hand mirrored to a left by scale.x=-1 would flip its winding (backface
// cull hides the front, and the inverted-hull outline inverts). So mirror the
// GEOMETRY properly: negate X on positions + normals AND reverse the triangle
// winding, yielding a true left hand the existing FrontSide/BackSide passes read
// unchanged.
function mirrorGeometry(geo) {
  const g = geo.clone();
  const p = g.attributes.position, n = g.attributes.normal;
  for (let i = 0; i < p.count; i++) { p.setX(i, -p.getX(i)); if (n) n.setX(i, -n.getX(i)); }
  p.needsUpdate = true; if (n) n.needsUpdate = true;
  const idx = g.index;
  if (idx) { const a = idx.array; for (let i = 0; i < a.length; i += 3) { const t = a[i + 1]; a[i + 1] = a[i + 2]; a[i + 2] = t; } idx.needsUpdate = true; }
  return g;
}
// One pose group: the same matcap body + inverted-hull outline the cube uses.
// Centered on its own bbox so it anchors and rotates like the capsule poses did.
function buildBakedPose(srcMesh, mirror) {
  const geo = mirror ? mirrorGeometry(srcMesh.geometry) : srcMesh.geometry.clone();
  geo.computeBoundingBox();
  const c = new THREE.Vector3(); geo.boundingBox.getCenter(c);
  geo.translate(-c.x, -c.y, -c.z);
  const body = new THREE.Mesh(geo, bodyMaterial());
  const g = new THREE.Group();
  g.add(hullOf(body, HAND_OUT));   // toon outline, same as the body's
  g.add(body);
  g.visible = false;
  return g;
}
function disposePoseGroup(g) {
  g.traverse(o => {
    if (o.geometry) o.geometry.dispose();
    if (o.material) { _bodyMats.delete(o.material); _outlineMats.delete(o.material); o.material.dispose(); }
  });
}

export function mount(container, cubeEl) {
  // renderer: transparent, oversized, centered on the container
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  renderer.setPixelRatio(dpr);
  renderer.setSize(CANVAS, CANVAS);
  const cv = renderer.domElement;
  cv.style.cssText = `position:absolute;left:${(SIZE - CANVAS) / 2}px;top:${(SIZE - CANVAS) / 2}px;` +
    `width:${CANVAS}px;height:${CANVAS}px;pointer-events:none;`;
  container.insertBefore(cv, container.firstChild);

  const scene = new THREE.Scene();
  const cam = new THREE.OrthographicCamera(-CANVAS / 2, CANVAS / 2, CANVAS / 2, -CANVAS / 2, -600, 600);
  cam.position.z = 300;

  // the tuned lighting, translated: bright ambient + a soft key from the
  // front-top so sides shade to ~80% (the old dark-48 look)
  scene.add(new THREE.AmbientLight(0xffffff, 2.35));
  const key = new THREE.DirectionalLight(0xffffff, 1.15);
  key.position.set(0.35, 0.7, 1);
  scene.add(key);

  const rig = new THREE.Group();                 // rotation rig (body + hands)
  let bodyGroup;
  scene.add(rig);
  bodyGroup = buildBody();
  rig.add(bodyGroup);

  // hands: the procedural capsule poses render IMMEDIATELY (point/open/thumb) so
  // there's never an empty hand; the richer baked set swaps in when the GLB lands.
  const handRigs = {};
  for (const side of ["r", "l"]) {
    const holder = new THREE.Group();
    const poses = {};
    for (const p of ["point", "open", "thumb"]) {
      const pg = buildHandPose(p, side === "l");
      poses[p] = pg;
      holder.add(pg);
    }
    holder.visible = false;
    rig.add(holder);
    handRigs[side] = { holder, poses };
  }

  const D = Math.PI / 180;
  const readVar = (el, name) => parseFloat(el.style.getPropertyValue(name)) || 0;

  let disposed = false;
  const faceEl = container.querySelector(".sc-face");

  // swap the capsule placeholders for the baked hand meshes once the GLB arrives.
  // Same matcap + inverted-hull shaders; on ANY failure the capsules just stay,
  // so this is a pure progressive-enhancement — the avatar never regresses.
  new GLTFLoader().load(HANDS_URL, gltf => {
    if (disposed) return;
    const byName = {};
    gltf.scene.traverse(o => { if (o.isMesh) byName[o.name] = o; });
    for (const side of ["r", "l"]) {
      const h = handRigs[side];
      for (const p in h.poses) { h.holder.remove(h.poses[p]); disposePoseGroup(h.poses[p]); }
      h.poses = {};
      for (const name of HAND_POSES) {
        const src = byName[name];
        if (!src) continue;
        const pg = buildBakedPose(src, side === "l");
        h.poses[name] = pg;
        h.holder.add(pg);
      }
    }
  }, undefined, () => { /* GLB unavailable → keep the procedural capsules */ });

  // SMOOTHING: the drivers step the CSS vars discretely (gestures ~130ms,
  // breathing ~90ms). The old CSS cube had `transition: transform .12s` to
  // glide between steps; rendering the raw values here made the body JUMP at
  // every step — the reported vibration. Exponential lerp restores the glide.
  const cur = { rx: 0, ry: 0, rz: 0 };
  const handCur = { r: { x: 0, y: 0, rot: 0, s: 0 }, l: { x: 0, y: 0, rot: 0, s: 0 } };
  const lerp = (a, b, t) => a + (b - a) * t;

  (function frame() {
    if (disposed) return;
    requestAnimationFrame(frame);

    _wobT.value = performance.now() / 1000;   // shared blob clock (bounded, no drift)

    // body rotation from the CSS vars the app already writes — smoothed
    const trx = readVar(cubeEl, "--rx") + readVar(cubeEl, "--nod") + readVar(cubeEl, "--br");
    const trY = readVar(cubeEl, "--ry");
    const trz = readVar(cubeEl, "--rz");
    cur.rx = lerp(cur.rx, trx, 0.22);
    cur.ry = lerp(cur.ry, trY, 0.22);
    cur.rz = lerp(cur.rz, trz, 0.22);
    const rx = cur.rx, ry = cur.ry, rz = cur.rz;
    rig.rotation.set(-rx * D, ry * D, -rz * D);

    // face overlay glue: shift the DOM face toward the front plane's projection
    if (faceEl) {
      // front plane (0,0,h) under rotation.x = -rx: y' = -h*sin(-rx*D) → the
      // CSS offset (y-down) is -h*sin(rx*D). The +sin version moved the face
      // AGAINST the body's pitch — the inverted vertical parallax.
      const fx = Math.sin(ry * D) * (SIZE / 2);
      const fy = -Math.sin(rx * D) * (SIZE / 2);
      faceEl.style.transform = `translate(${fx.toFixed(1)}px, ${fy.toFixed(1)}px)`;
    }

    // hands follow their controller divs (position/rotation/scale/pose)
    for (const side of ["r", "l"]) {
      const ctrl = container.querySelector("#vs-hand-" + side);
      const h = handRigs[side];
      if (!ctrl) { h.holder.visible = false; continue; }
      const po = parseFloat(ctrl.style.getPropertyValue("--po")) || 0;
      const hs = parseFloat(ctrl.style.getPropertyValue("--hs")) || 0;
      if (po < 0.05 || hs < 0.05) { h.holder.visible = false; continue; }
      const hc = handCur[side];
      hc.x = lerp(hc.x, readVar(ctrl, "--hx") + 15, 0.3);   // controller top-left → center
      hc.y = lerp(hc.y, readVar(ctrl, "--hy") + 20, 0.3);
      hc.rot = lerp(hc.rot, readVar(ctrl, "--hr"), 0.3);
      hc.s = lerp(hc.s, hs, 0.3);
      h.holder.visible = true;
      h.holder.position.set(hc.x - SIZE / 2, SIZE / 2 - hc.y, 76);
      h.holder.rotation.z = -hc.rot * D;
      h.holder.scale.setScalar(Math.max(0.001, hc.s));
      // pick the requested pose; if it isn't available (baked set still loading,
      // or a name only the capsules lack), fall back so a hand always shows.
      const want = ctrl.dataset.pose || "point";
      const pose = h.poses[want] ? want
                 : h.poses.point ? "point"
                 : (Object.keys(h.poses)[0] || null);
      for (const p in h.poses) h.poses[p].visible = (p === pose);
    }

    renderer.render(scene, cam);
  })();

  // swap the body geometry for a new shape preset, disposing the old one
  function setShape(key) {
    const next = buildBody(key);
    if (bodyGroup) {
      rig.remove(bodyGroup);
      bodyGroup.traverse(o => {
        if (o.geometry) o.geometry.dispose();
        if (o.material) { _bodyMats.delete(o.material); _outlineMats.delete(o.material); o.material.dispose(); }
      });
    }
    bodyGroup = next;
    rig.add(bodyGroup);
  }
  // rebuild geometry only when the SHAPE actually changed (recolor is handled by
  // _reskin); color-only swatch changes must not thrash the extrude geometry.
  let _lastShape = currentShape();
  const _onChar = () => {
    const s = currentShape();
    if (s !== _lastShape) { _lastShape = s; setShape(s); }
  };
  window.addEventListener("characterchange", _onChar);

  return {
    setShape,
    dispose() {
      disposed = true;
      window.removeEventListener("characterchange", _onChar);
      renderer.dispose();
      cv.remove();
    }
  };
}

window.Avatar3D = { mount };
