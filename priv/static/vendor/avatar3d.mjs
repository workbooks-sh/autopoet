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

const SIZE = 132;          // cube edge in px == world units
const R = 35;              // squircle corner radius
const INK = 0x121316;
const CANVAS = 340;        // oversized so hands + outline never clip
const OUT = 2.6;           // outline thickness (world units at scale 1)

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

// materials shared by everything (body + hands): warm white, soft side shading
function bodyMaterial() {
  return new THREE.MeshLambertMaterial({ color: 0xffffff });
}
function outlineMaterial() {
  return new THREE.MeshBasicMaterial({ color: INK, side: THREE.BackSide });
}

// inverted hull: same geometry pushed out along normals by `w` world units
function hullOf(mesh, w) {
  const geo = mesh.geometry.clone();
  const pos = geo.attributes.position, nor = geo.attributes.normal;
  for (let i = 0; i < pos.count; i++) {
    pos.setXYZ(i,
      pos.getX(i) + nor.getX(i) * w,
      pos.getY(i) + nor.getY(i) * w,
      pos.getZ(i) + nor.getZ(i) * w);
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

// ── the body: extruded squircle with beveled (soft) front/back edges ──
function buildBody() {
  const depth = SIZE - 16;
  const geo = new THREE.ExtrudeGeometry(roundedRectShape(SIZE - 12, SIZE - 12, R), {
    depth, bevelEnabled: true, bevelThickness: 8, bevelSize: 6, bevelSegments: 4, curveSegments: 10
  });
  geo.translate(0, 0, -depth / 2);            // center on origin
  geo.computeVertexNormals();
  const mesh = new THREE.Mesh(geo, bodyMaterial());
  return withHull(mesh);
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
  scene.add(rig);
  rig.add(buildBody());

  // hands: three pose groups per side, driven by the controller divs
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
      const pose = ctrl.dataset.pose || "point";
      for (const p in h.poses) h.poses[p].visible = (p === pose);
    }

    renderer.render(scene, cam);
  })();

  return {
    dispose() {
      disposed = true;
      renderer.dispose();
      cv.remove();
    }
  };
}

window.Avatar3D = { mount };
