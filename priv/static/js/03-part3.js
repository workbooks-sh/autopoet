// ══ NEW-IN-VAULT — a per-kind form (no re-picking): name · destination · type · tags · icon ══
const KINDS = {
  note:      { title: "document",  icon: "markdown", hasType: true,  ext: "" },
  sketch:    { title: "sketch",    icon: "svg",      hasType: true,  ext: ".sketch.svg" },
  folder:    { title: "folder",    icon: "folder",   hasType: false, ext: "" },
  workspace: { title: "workspace", icon: "hash",     hasType: false, ext: "" }
};
const TYPES = {
  program: { label: "Program", icon: "blocks",    desc: "Baked into the build — changes instantiate real structure." },
  context: { label: "Context", icon: "book-open", desc: "Read-only reference — it informs, never instantiates." }
};
let lastFocusDir = "";     // new items default here — the last folder/workspace you touched
let micnames = null;       // full icon list, lazy-loaded for the picker
let mv = { kind: "note", dest: "", icon: "markdown", type: "program", tags: [], edit: false, origPath: null, name: "" };

function showModal() {
  renderModal();
  document.getElementById("shade").classList.add("on");
  document.getElementById("modal").classList.add("on");
  setTimeout(() => { const i = document.getElementById("modalname"); if (i) { i.focus(); if (mv.edit) i.select(); } }, 60);
}
function openModal(kind) {
  const k = KINDS[kind];
  mv = { kind, dest: lastFocusDir, icon: k.icon, type: "program", tags: [], edit: false, origPath: null, name: "" };
  showModal();
}
// folder context-menu path ("new document inside") — reuse with a preset destination
function openModalPrefixed(kind, prefix) { openModal(kind); mv.dest = prefix.replace(/\/$/, ""); renderModal(); }

// double-click / rename → open the SAME modal in EDIT mode (name + dest + type + tags + icon)
function findNode(items, path) {
  for (const n of items || []) { if (n.path === path) return n; const c = findNode(n.children, path); if (c) return c; }
  return null;
}
function editItem(path) {
  const node = findNode(vaultTree, path); if (!node) return;
  const kind = node.type, meta = node.meta || {};
  let name = path.slice(path.lastIndexOf("/") + 1);
  if (kind === "sketch") name = name.replace(/\.sketch\.svg$/, "");
  mv = { kind, dest: path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "",
         icon: meta.icon || KINDS[kind].icon, type: meta.type || "program",
         tags: [...(meta.tags || [])], edit: true, origPath: path, name };
  showModal();
}

const destLabel = () => mv.dest ? mv.dest.split("/").join(" / ") : "vault root";

function renderModal() {
  const k = KINDS[mv.kind];
  const typeRow = k.hasType ? `
    <div class="typecards">${Object.entries(TYPES).map(([t, v]) =>
      `<button class="tycard ${mv.type === t ? "sel" : ""}" data-type="${t}">
         <i data-lucide="${v.icon}"></i>
         <div><div class="tyt">${v.label}</div><div class="tyd">${v.desc}</div></div></button>`).join("")}</div>` : "";
  document.getElementById("modal").innerHTML = `
    <div class="mhd">
      <button id="mIcon" class="iconbtn" title="choose an icon">${iconFor(mv.kind, mv.icon, 22)}</button>
      <div class="mtitle">${mv.edit ? "Edit" : "New"} ${k.title}</div>
    </div>
    <button id="mDest" class="destbc" title="choose where it goes">
      <i data-lucide="corner-down-right"></i><span>${esc(destLabel())}</span><i data-lucide="chevron-down"></i>
    </button>
    <input id="modalname" value="${esc(mv.name || "")}" placeholder="name${KINDS[mv.kind].ext ? "" : " (nest with /)"}" spellcheck="false">
    ${typeRow}
    <div class="mrow"><span class="ml">tags</span>
      <div class="tagbox" id="mTagbox">
        ${mv.tags.map(t => `<span class="tag">${esc(t)}<b data-rm="${esc(t)}">×</b></span>`).join("")}
        <input id="mTagin" placeholder="${mv.tags.length ? "" : "add a tag…"}" spellcheck="false">
      </div>
    </div>
    <div class="acts">
      <button id="modalcancel">cancel</button>
      <button class="go" id="modalgo">${mv.edit ? "save changes" : "create " + k.title}</button>
    </div>`;
  refreshIcons();
  bindModal();
}
function bindModal() {
  const $ = id => document.getElementById(id);
  $("modalcancel").onclick = closeModal;
  $("modalgo").onclick = createFromModal;
  $("mIcon").onclick = e => { e.stopPropagation(); openIconPop(); };
  $("mDest").onclick = e => { e.stopPropagation(); openDestPop(); };
  const name = $("modalname");
  name.onkeydown = e => { if (e.key === "Enter") createFromModal(); if (e.key === "Escape") closeModal(); };
  document.querySelectorAll("#modal .tycard").forEach(b =>
    b.onclick = () => { mv.type = b.dataset.type; mv.name = $("modalname").value; renderModal(); });
  name.oninput = () => { mv.name = name.value; };   // preserve the typed name across re-renders
  const ti = $("mTagin");
  ti.onkeydown = e => {
    if (e.key === "Enter" || e.key === ",") {
      e.preventDefault();
      const v = ti.value.trim().replace(/^[#@]/, "");
      if (v && !mv.tags.includes(v)) mv.tags.push(v);
      renderModal(); setTimeout(() => $("mTagin")?.focus(), 0);
    } else if (e.key === "Backspace" && !ti.value && mv.tags.length) {
      mv.tags.pop(); renderModal(); setTimeout(() => $("mTagin")?.focus(), 0);
    }
  };
  document.querySelectorAll("#mTagbox b[data-rm]").forEach(b =>
    b.onclick = () => { mv.tags = mv.tags.filter(t => t !== b.dataset.rm); renderModal(); });
}
function createFromModal() {
  const name = document.getElementById("modalname").value.trim();
  if (!name) return;
  const k = KINDS[mv.kind];
  const base = (mv.dest ? mv.dest + "/" : "") + name;
  const path = k.ext && !base.endsWith(k.ext) ? base + k.ext : base;
  const metaQ = `icon=${encodeURIComponent(mv.icon)}&type=${mv.type}&tags=${encodeURIComponent(mv.tags.join(","))}`;

  if (mv.edit) {
    const saveMeta = () => fetch(`/notes/meta?path=${encodeURIComponent(path)}&${metaQ}`, { method: "POST", ...authed });
    const moved = path !== mv.origPath;
    const step = moved
      ? fetch(`/notes/rename?from=${encodeURIComponent(mv.origPath)}&to=${encodeURIComponent(path)}`, { method: "POST", ...authed }).then(saveMeta)
      : saveMeta();
    step.then(() => {
      if (moved && buffers[mv.origPath]) { buffers[path] = buffers[mv.origPath]; delete buffers[mv.origPath]; persistBuffers(); }
      if (open.path === mv.origPath) { open.path = path; document.getElementById("fname").textContent = fileLabel(path); }
      return loadTree();
    }).then(() => { closeModal(); draw(); });
  } else {
    fetch(`/notes/new?path=${encodeURIComponent(path)}&kind=${mv.kind}&${metaQ}`, { method: "POST", ...authed })
      .then(() => loadTree())
      .then(() => { closeModal(); if (mv.kind !== "folder" && mv.kind !== "workspace") openFile(path, mv.kind); });
  }
}
document.getElementById("newnote").onclick = () => openModal("note");
document.getElementById("newsketch").onclick = () => openModal("sketch");
document.getElementById("newfolder").onclick = () => openModal("folder");
document.getElementById("newworkspace").onclick = () => openModal("workspace");

