// ── sidebar footer: account · settings · env ──────────────────────────────
function toast(msg) {
  let t = document.getElementById("aptoast");
  if (!t) {
    t = document.createElement("div"); t.id = "aptoast"; document.body.appendChild(t);
    t.style = "position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:#223;color:#fff;padding:8px 14px;border-radius:9px;font:12px ui-monospace,monospace;z-index:80;opacity:0;transition:opacity .2s ease;pointer-events:none";
  }
  t.textContent = msg; t.style.opacity = "1";
  clearTimeout(t._h); t._h = setTimeout(() => t.style.opacity = "0", 1600);
}
function openFootPop(anchor, html) {
  const p = document.getElementById("footpop");
  p.innerHTML = html; p.classList.add("on"); refreshIcons();
  const r = anchor.getBoundingClientRect();
  requestAnimationFrame(() => {
    p.style.left = Math.max(8, Math.min(r.left, innerWidth - p.offsetWidth - 8)) + "px";
    p.style.top = "auto"; p.style.bottom = (innerHeight - r.top + 8) + "px";
  });
}
function closeFootPop() { const p = document.getElementById("footpop"); p.classList.remove("on"); p.innerHTML = ""; }
addEventListener("mousedown", e => {
  const p = document.getElementById("footpop");
  if (p.classList.contains("on") && !p.contains(e.target) && !e.target.closest("#sidebarfoot")) closeFootPop();
});

// profile · sign out (real) + billing (stub)
document.getElementById("foot-profile").onclick = e => {
  e.stopPropagation();
  const u = currentUser || { name: "guest", email: "" };
  const ini = (u.name || "·").slice(0, 1).toLowerCase();
  openFootPop(e.currentTarget, `
    <div class="fp-head"><span class="fp-av">${esc(ini)}</span><div><div class="fp-name">${esc(u.name || "guest")}</div><div class="fp-mail">${esc(u.email || "")}</div></div></div>
    <div class="fp-sep"></div>
    <button class="fp-item" data-act="billing"><i data-lucide="credit-card"></i>billing</button>
    <button class="fp-item danger" data-act="signout"><i data-lucide="log-out"></i>sign out</button>`);
  document.querySelector('#footpop [data-act="billing"]').onclick = () => { closeFootPop(); toast("billing — coming soon"); };
  document.querySelector('#footpop [data-act="signout"]').onclick = () => {
    closeFootPop();
    // full sign-out: revoke+drop the cloud PAT, clear the local session, and open
    // the cloud logout so the browser session clears too → the door gates fresh.
    authedPost("/auth/cloud/signout").then(r => r.json().catch(() => ({}))).then(d => {
      if (d && d.logout_url) { try { window.open(d.logout_url, "_blank"); } catch (_) {} }
      location.reload();
    }).catch(() => location.reload());
  };
};

// settings · theme (persisted) + app config
function applyTheme(t) {
  document.documentElement.setAttribute("data-theme", t);
  localStorage.setItem("ap-theme", t);
  window.dispatchEvent(new CustomEvent("themechange", { detail: { theme: t } }));
  applyCharacter();   // the AutoPoet's color is theme-tuned — recompute for the new theme
  // match the native window chrome (frame + drag strip) — desktop only, harmless elsewhere
  try { fetch("/chrome-theme?t=" + encodeURIComponent(t), { method: "POST" }).catch(() => {}); } catch (_) {}
}

// ══ AutoPoet character — color + shape, INDEPENDENT of the light/dark UI theme ══
// The avatar looks the SAME in light and dark: one body color per swatch, with
// eyes/mouth features auto-picked for contrast. Only the toon OUTLINE follows the
// theme (black in light, white in dark) — handled by --face-outline, not here.
// A white + a dark neutral, then soft pastels.
const AP_PALETTE = [
  { key: "white",   name: "White",   body: "#ffffff" },
  { key: "dark",    name: "Dark",    body: "#2a2f37" },
  { key: "mint",    name: "Mint",    body: "#dcf2e5" },
  { key: "sky",     name: "Sky",     body: "#dbecf8" },
  { key: "blue",    name: "Blue",    body: "#d7e6f5" },
  { key: "violet",  name: "Violet",  body: "#ede5f8" },
  { key: "rose",    name: "Rose",    body: "#f6dbeb" },
  { key: "peach",   name: "Peach",   body: "#fae7da" },
  { key: "cream",   name: "Cream",   body: "#faf0dd" },
  { key: "sage",    name: "Sage",    body: "#e9f2dd" },
];
const AP_SHAPES = [{ key: "squircle", name: "Squircle" }, { key: "round", name: "Round" }, { key: "blocky", name: "Blocky" }];

// eyes/mouth: dark ink on light/pastel bodies, light ink on the dark body
function faceFeatures(hex) {
  const n = parseInt(hex.slice(1), 16), r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 140 ? "#1c2230" : "#eef1f5";
}
function getChar() {
  let c = {};
  try { c = JSON.parse(localStorage.getItem("ap-character") || "{}"); } catch (_) {}
  return {
    color: AP_PALETTE.some(p => p.key === c.color) ? c.color : "white",
    shape: AP_SHAPES.some(s => s.key === c.shape) ? c.shape : "squircle",
  };
}
function setChar(patch) {
  const c = { ...getChar(), ...patch };
  try { localStorage.setItem("ap-character", JSON.stringify(c)); } catch (_) {}
  return c;
}
// paint the character: body + auto features as inline overrides (theme-independent),
// set the shape attribute, then tell the 3D cube to update. Outline stays theme-driven.
function applyCharacter() {
  const c = getChar();
  const sw = AP_PALETTE.find(p => p.key === c.color) || AP_PALETTE[0];
  document.documentElement.style.setProperty("--face-bg", sw.body);
  document.documentElement.style.setProperty("--face-features", faceFeatures(sw.body));
  document.documentElement.setAttribute("data-ap-shape", c.shape);
  window.dispatchEvent(new CustomEvent("characterchange", { detail: c }));
}

