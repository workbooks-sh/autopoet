// ── rename (double-click in header or tree; extension is free-form) ───────
async function renameNote(from, kind) {
  const base = from.split("/").pop();
  const to = await askRename(base);
  if (!to || to === base) return;
  const dir = from.includes("/") ? from.slice(0, from.lastIndexOf("/") + 1) : "";
  const target = dir + to;
  await fetch(`/notes/rename?from=${encodeURIComponent(from)}&to=${encodeURIComponent(target)}`,
    { method: "POST", ...authed });
  if (buffers[from]) { buffers[target] = buffers[from]; delete buffers[from]; persistBuffers(); }
  if (open.path === from) { open.path = target; document.getElementById("fname").textContent = target; }
  loadTree(); draw();
}
function askRename(current) {
  // inline, in-theme: reuse the modal frame as a tiny rename dialog
  return new Promise(resolve => {
    openModalRaw(`<h3>RENAME</h3>
      <input id="modalname" value="${esc(current)}" spellcheck="false">
      <div class="acts"><button id="modalcancel">cancel</button>
      <button class="go" id="modalgo">rename</button></div>`);
    const inp = document.getElementById("modalname");
    setTimeout(() => { inp.focus(); inp.select(); }, 60);
    const done = v => { closeModal(); resolve(v); };
    document.getElementById("modalcancel").onclick = () => done(null);
    document.getElementById("modalgo").onclick = () => done(inp.value.trim());
    inp.onkeydown = e => {
      if (e.key === "Enter") done(inp.value.trim());
      if (e.key === "Escape") done(null);
    };
  });
}
document.getElementById("fname").addEventListener("dblclick", () => {
  if (open.path && open.src !== "body") editItem(open.path);
});

function deleteNote(path) {
  fetch(`/notes/delete?path=${encodeURIComponent(path)}`, { method: "POST", ...authed })
    .then(() => {
      delete buffers[path]; persistBuffers();
      if (open.path === path) document.getElementById("closeed").onclick();
      loadTree(); draw(); updateDirtyUI();
    });
}

// ── tree drag-drop: set-list order + move into folders ────────────────────
let dragging = null;
function bindTreeDnD() {
  document.querySelectorAll("#tree .row").forEach(el => {
    el.draggable = true;
    el.addEventListener("dragstart", e => { dragging = el; e.dataTransfer.effectAllowed = "move"; });
    el.addEventListener("dragover", e => { e.preventDefault(); el.classList.add("dragover"); });
    el.addEventListener("dragleave", () => el.classList.remove("dragover"));
    el.addEventListener("drop", async e => {
      e.preventDefault(); el.classList.remove("dragover");
      if (!dragging || dragging === el) return;
      const from = dragging.dataset.path, name = from.split("/").pop();
      if (el.dataset.folder !== undefined) {
        // into the folder
        await fetch(`/notes/rename?from=${encodeURIComponent(from)}&to=${encodeURIComponent(el.dataset.path + "/" + name)}`,
          { method: "POST", ...authed });
      } else if (el.dataset.path) {
        const toDir = el.dataset.path.includes("/") ? el.dataset.path.slice(0, el.dataset.path.lastIndexOf("/")) : "";
        const fromDir = from.includes("/") ? from.slice(0, from.lastIndexOf("/")) : "";
        if (toDir !== fromDir) {
          await fetch(`/notes/rename?from=${encodeURIComponent(from)}&to=${encodeURIComponent((toDir ? toDir + "/" : "") + name)}`,
            { method: "POST", ...authed });
        }
        // reorder: place the dragged name before the drop target within its dir
        const rows = [...document.querySelectorAll(`#tree .row`)].filter(r => {
          const p = r.dataset.path || "";
          const d = p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "";
          return d === toDir && p;
        }).map(r => (r.dataset.path || "").split("/").pop());
        const without = rows.filter(n => n !== name);
        without.splice(without.indexOf(el.dataset.path.split("/").pop()), 0, name);
        await fetch(`/notes/reorder?dir=${encodeURIComponent(toDir)}&names=${encodeURIComponent(without.join("\n"))}`,
          { method: "POST", ...authed });
      }
      dragging = null;
      loadTree(); draw();
    });
  });
}

// ── canvas badges: morphing search + notifications drawer ─────────────────
const searchpop = document.getElementById("searchpop"), notif = document.getElementById("notif");
const cbSearch = document.getElementById("cb-search"), canvasbar = document.getElementById("canvasbar");

function syncActive() {
  canvasbar.classList.toggle("active",
    cbSearch.classList.contains("expanded") || notif.classList.contains("on"));
}
function collapseSearch() {
  cbSearch.classList.remove("expanded");
  searchpop.classList.remove("on");
  document.getElementById("searchin").value = "";
  document.getElementById("searchres").innerHTML = "";
  clearSearchDim(); syncActive();
}
cbSearch.addEventListener("click", e => {
  if (cbSearch.classList.contains("expanded")) return;   // clicks inside the bar are for the input
  notif.classList.remove("on");
  cbSearch.classList.add("expanded");
  syncActive();
  setTimeout(() => document.getElementById("searchin").focus(), 120);
});
document.getElementById("searchin").addEventListener("keydown", e => {
  if (e.key === "Escape") collapseSearch();
});
document.getElementById("searchin").addEventListener("blur", () => {
  setTimeout(() => { if (!document.getElementById("searchin").value.trim()) collapseSearch(); }, 150);
});
document.getElementById("cb-bell").onclick = () => {
  collapseSearch();
  notif.classList.toggle("on");
  syncActive();
};

function clearSearchDim() { g.selectAll("g > g").attr("opacity", 1); applyFilter(); }

