// ── GLOBAL DIRTY REGISTRY (IDE-grade) ─────────────────────────────────────
// Every unsaved buffer lives here, keyed by path — any number of files can be
// dirty at once. Saving happens ONLY by ⌘S/button (command mode) or debounce
// (live mode). Never on panel close, file switch, or app exit: buffers persist
// to localStorage (hot exit) and are restored on load.
let buffers = {};
try { buffers = JSON.parse(localStorage.getItem("ap-buffers") || "{}"); } catch (_) {}
const dirtyCount = () => Object.keys(buffers).length;
const persistBuffers = () => localStorage.setItem("ap-buffers", JSON.stringify(buffers));

function markDirty(key, kind, content) {
  const first = !buffers[key];
  buffers[key] = { content, kind };
  persistBuffers();
  if (first) updateDirtyUI(); else updatePill();
  if (openKey() === key) setDot("dirty");
}
function clearDirty(key) {
  delete buffers[key];
  persistBuffers();
  updateDirtyUI();
  if (openKey() === key) setDot("saved");
}
// buffer keys: vault buffers are plain paths; body (.work) buffers ride a
// "work:" prefix and save through /body/save (the human edits their organism
// directly — the gate constrains the machine, not you)
const openKey = () => open.path ? (open.src === "body" ? "work:" + open.path : open.path) : null;
async function saveOne(key) {
  const b = buffers[key];
  if (!b) return;
  const body = key.startsWith("work:");
  const url = body
    ? "/body/save?path=" + encodeURIComponent(key.slice(5))
    : "/notes/save?path=" + encodeURIComponent(key);
  await fetch(url, { method: "POST", body: b.content, ...authed });
  clearDirty(key);
  if (body) { draw(); refreshUndoState(); }   // the organism changed — refresh the world + undo state
}
async function saveAll() {
  for (const path of Object.keys(buffers)) await saveOne(path);
}
function updateDirtyUI() {
  document.querySelectorAll("#tree .row[data-path]").forEach(el =>
    el.classList.toggle("isdirty", !!buffers[el.dataset.path]));
  updatePill();
}
// command mode + dirty buffers ⇒ the cmd/live toggle transforms into revert/save
// (you can't switch to live mid-save because the toggle literally isn't there)
function updatePill() {
  document.getElementById("modetoggle").classList.toggle("saving",
    mode === "command" && dirtyCount() > 0);
}

async function openFile(path, kind) {
  if (commState === "chat") setComm(null);   // a file and the chat share the slot
  lastFocusDir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  // never commits anything: the previous file's buffer stays in the registry
  const buffered = buffers[path];
  const content = buffered ? buffered.content
    : await (await fetch("/notes/file?path=" + encodeURIComponent(path))).text();
  open = { path, kind, src: "vault" };
  document.getElementById("fname").textContent = fileLabel(path);
  document.getElementById("app").classList.add("editing");
  document.getElementById("app").classList.toggle("sketching", kind === "sketch");
  if (kind === "sketch") loadSketch(content);
  else document.getElementById("prose").value = content;
  setDot(buffered ? "dirty" : "saved");
  loadTree();
  relayout();
}
document.getElementById("closeed").onclick = () => {
  // closing NEVER saves — buffers live in the registry regardless of mode
  document.getElementById("app").classList.remove("editing", "sketching");
  open = { path: null, kind: null };
  loadTree();
  relayout();
};

// open a BODY page (.work) in the editor — the pencil on a graph node
async function openBody(path) {
  if (commState === "chat") setComm(null);
  const key = "work:" + path;
  const buffered = buffers[key];
  const content = buffered ? buffered.content
    : await (await fetch("/body/file?path=" + encodeURIComponent(path))).text();
  open = { path, kind: "note", src: "body" };
  document.getElementById("fname").textContent = "⚙ " + path;
  document.getElementById("app").classList.add("editing");
  document.getElementById("app").classList.remove("sketching");
  document.getElementById("prose").value = content;
  setDot(buffered ? "dirty" : "saved");
  relayout();
}

// ── save mode: COMMAND ONLY (live is gone) ─────────────────────────────────
// edits wait in buffers; the save prompt (revert/✓) appears while anything is
// dirty; ⌘S saves & translates.
const mode = "command";
document.getElementById("dosave").onclick = () => saveAll();
document.getElementById("dorevert").onclick = () => revertAll();

// revert: drop every unsaved buffer, restore the on-disk content of the open file
async function revertAll() {
  const wasOpen = open.path && buffers[openKey()];
  buffers = {}; persistBuffers();
  if (wasOpen) {
    const url = open.src === "body" ? "/body/file?path=" : "/notes/file?path=";
    const content = await (await fetch(url + encodeURIComponent(open.path))).text();
    if (open.kind === "sketch") loadSketch(content); else document.getElementById("prose").value = content;
  }
  clearTimeout(saveTimer); saveTimer = null;
  updateDirtyUI(); setDot("saved");
}

addEventListener("keydown", e => {
  if ((e.metaKey || e.ctrlKey) && e.key === "s") {
    e.preventDefault();
    saveAll();
  }
});

let saveTimer = null;
function setDot(cls) { document.getElementById("savedot").className = "dot " + cls; }
// an edit only updates the registry — nothing writes until the human saves
function onEdit() {
  if (!open.path) return;
  const content = open.kind === "sketch" ? serializeSketch() : document.getElementById("prose").value;
  markDirty(openKey(), open.kind, content);
}
document.getElementById("prose").addEventListener("input", onEdit);

