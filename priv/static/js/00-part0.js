const TOKEN = window.TOKEN;
const authed = { headers: { authorization: `Bearer ${TOKEN}` } };

// ── window chrome ─────────────────────────────────────────────────────────
function win(a) { fetch("/win/" + a, { method: "POST", ...authed }); }
document.querySelector("#chrome .close")?.addEventListener("click", () => win("close"));
document.querySelector("#chrome .min")?.addEventListener("click", () => win("minimize"));
document.querySelector("#chrome .max")?.addEventListener("click", () => win("maximize"));

// ── error surfacing (no devtools in the webview) ─────────────────────────
function fatal(msg) {
  let b = document.getElementById("err");
  if (!b) { b = document.createElement("pre"); b.id = "err";
    b.style = "position:fixed;top:8px;right:8px;z-index:99;background:#fdecea;color:#a00;padding:8px;border-radius:6px;max-width:60vw;white-space:pre-wrap";
    document.body.appendChild(b); }
  b.textContent = "error: " + msg;
}
addEventListener("error", e => fatal(e.message + " @ " + e.filename + ":" + e.lineno));
addEventListener("unhandledrejection", e => fatal(String(e.reason)));

// ══ VAULT ═══════════════════════════════════════════════════════════════
// VS Code Material Icon Theme file icons (vendored SVGs, served from /static/micons)
const mic = n => `<img class="mic" src="/static/micons/${n}.svg" alt="">`;
const ICONS = {
  folder: mic("folder"), folderOpen: mic("folder-open"),
  note: mic("markdown"), sketch: mic("svg")
};
const DEF_ICON = { note: "markdown", sketch: "svg", folder: "folder", workspace: "hash" };
const micUrl = n => `/static/micons/${n}.svg`;
const micTag = (n, sz = 18) => n === "hash"
  ? `<span class="hashtag" style="font-size:${sz}px">#</span>`
  : `<img class="mic" style="width:${sz}px;height:${sz}px" src="${micUrl(n)}" alt="">`;
// folder & workspace keep their SHAPE + gray tone; a picked icon COMPOSES into the
// bottom-right corner (like the Material folder system) rather than replacing the base.
function iconFor(kind, icon, sz) {
  const b = Math.round(sz * 0.74);
  // CUTOUT (three nested layers, order matters): the INNER .csil paints the surround
  // colour masked to the icon's alpha = an icon-shaped silhouette; the OUTER .cmask
  // runs the #goo grow/smooth filter ON that silhouette (CSS applies filter before
  // mask, so the filter MUST wrap the masked child, not carry the mask itself); the
  // icon sits on top in the resulting clean cutout.
  const badge = (name, def, cls) => name && name !== def
    ? `<span class="cbadge ${cls || ""}" style="width:${b}px;height:${b}px">
         <span class="cmask"><span class="csil" style="-webkit-mask-image:url(${micUrl(name)});mask-image:url(${micUrl(name)})"></span></span>
         <img src="${micUrl(name)}" style="width:100%;height:100%" alt=""></span>` : "";
  if (kind === "folder" || kind === "folderOpen")
    return `<span class="composed">${micTag(kind === "folderOpen" ? "folder-open" : "folder", sz)}${badge(icon, "folder")}</span>`;
  if (kind === "workspace")
    return `<span class="composed"><span class="hashtag" style="font-size:${sz}px">#</span>${badge(icon, "hash", "cbadge-ws")}</span>`;
  return micTag(icon, sz);
}
const refreshIcons = () => window.lucide && lucide.createIcons();
let open = { path: null, kind: null, dirty: false };
let vaultTree = [];   // the current tree — feeds the new-item destination picker

async function loadTree() {
  const tree = await (await fetch("/notes/tree.json")).json();
  vaultTree = tree;
  document.getElementById("treeroot").innerHTML = renderTree(tree);
  document.querySelectorAll("#tree .row[data-path]").forEach(el => {
    const path = el.dataset.path, kind = el.dataset.kind, folder = el.dataset.folder !== undefined;
    if (!folder) el.onclick = () => openFile(path, kind);
    if (folder) el.onclick = () => {
      lastFocusDir = path;   // new items default into the folder/workspace you last touched
      const nowClosed = !closedFolders.has(path);
      if (nowClosed) closedFolders.add(path); else closedFolders.delete(path);
      persistFolders();
      el.classList.toggle("openf", !nowClosed);
      el.parentElement.querySelector("ul")?.classList.toggle("hide", nowClosed);
      // swap the material folder icon open/closed (only the default folder icon —
      // a custom-picked icon stays put)
      const img = el.querySelector("img.mic");
      if (img && /\/(folder|folder-open)\.svg$/.test(img.getAttribute("src") || ""))
        img.src = `/static/micons/${nowClosed ? "folder" : "folder-open"}.svg`;
    };
    if (path === open.path) el.classList.add("open");
    el.classList.toggle("isdirty", !!buffers[path]);
    el.addEventListener("dblclick", () => editItem(path));
    el.addEventListener("contextmenu", e => {
      e.preventDefault();
      const items = [];
      if (!folder) items.push({ icon: "external-link", label: "open", fn: () => openFile(path, kind) });
      if (folder) items.push(
        { icon: "file-plus-2", label: "new document inside", fn: () => openModalPrefixed("note", path + "/") },
        { icon: "pen-tool", label: "new sketch inside", fn: () => openModalPrefixed("sketch", path + "/") });
      items.push({ icon: "pencil", label: "edit", fn: () => editItem(path) }, "-",
        { icon: "trash-2", label: "delete", danger: true, fn: () => deleteNote(path) });
      showCtx(e.clientX, e.clientY, items);
    });
  });
  bindTreeDnD();
  refreshIcons();
}

// tree background: create things
document.getElementById("tree").addEventListener("contextmenu", e => {
  if (e.target.closest(".row")) return;
  e.preventDefault();
  showCtx(e.clientX, e.clientY, [
    { icon: "file-plus-2", label: "new document", fn: () => openModal("note") },
    { icon: "pen-tool", label: "new sketch", fn: () => openModal("sketch") },
    { icon: "folder-plus", label: "new folder", fn: () => openModal("folder") }
  ]);
});
// folders remember their open/closed state (default open); closed set persists
let closedFolders = new Set();
try { closedFolders = new Set(JSON.parse(localStorage.getItem("ap-closed") || "[]")); } catch (_) {}
const persistFolders = () => localStorage.setItem("ap-closed", JSON.stringify([...closedFolders]));

const treeIcon = n => (n.meta && n.meta.icon) || DEF_ICON[n.type];
const tagChips = n => {
  const tags = (n.meta && n.meta.tags) || [];
  return tags.length ? `<span class="rtags">${tags.map(t => `<span class="rtag">${esc(t)}</span>`).join("")}</span>` : "";
};
// program vs context, at a glance — a small glyph right of a file's name
const typeMark = n => {
  if (n.type !== "note" && n.type !== "sketch") return "";
  const t = (n.meta && n.meta.type) === "context" ? "context" : "program";
  return `<i class="tymark ty-${t}" data-lucide="${t === "context" ? "book-open" : "blocks"}" title="${t}"></i>`;
};
function renderTree(items) {
  return items.map(n => {
    if (n.type === "workspace") {
      const closed = closedFolders.has(n.path);
      return `<li><div class="row wsrow ${closed ? "" : "openf"}" data-path="${esc(n.path)}" data-folder data-ws>
        ${iconFor("workspace", treeIcon(n), 16)}<span>${esc(n.name)}</span>${tagChips(n)}</div>
        <ul class="${closed ? "hide" : ""}">${renderTree(n.children || [])}</ul></li>`;
    }
    if (n.type === "folder") {
      const closed = closedFolders.has(n.path);
      return `<li><div class="row ${closed ? "" : "openf"}" data-path="${esc(n.path)}" data-folder>
        <span class="tw"><i data-lucide="chevron-right"></i></span>
        ${iconFor(closed ? "folder" : "folderOpen", treeIcon(n), 16)}<span>${esc(n.name)}</span>${tagChips(n)}</div>
        <ul class="${closed ? "hide" : ""}">${renderTree(n.children || [])}</ul></li>`;
    }
    return `<li><div class="row" data-path="${esc(n.path)}" data-kind="${n.type}">${iconFor(n.type, treeIcon(n), 16)}<span>${esc(n.name)}</span>${typeMark(n)}${tagChips(n)}</div></li>`;
  }).join("");
}
const esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
// editor header: just the file name + its extension (no path); no extension ⇒ .md
function fileLabel(path) {
  const base = path.slice(path.lastIndexOf("/") + 1);
  if (base.endsWith(".sketch.svg")) return base;
  return base.includes(".") ? base : base + ".md";
}

