// ══ @-mention: search + reference a vault item from inside the editor ══
// Markdown already owns '#' (headings), so ALL references go through '@' — files,
// folders, workspaces — and insert an Obsidian-style [[backlink]] the graph + brain
// already understand.
const proseEl = document.getElementById("prose");
let mentionItems = [], mentionSel = 0, mentionRange = null;

function flatVault(items, acc) {
  for (const n of items || []) {
    acc.push({ name: n.name, path: n.path, type: n.type, meta: n.meta });
    if (n.children) flatVault(n.children, acc);
  }
  return acc;
}
function mentionContext() {
  const pos = proseEl.selectionStart;
  const m = proseEl.value.slice(0, pos).match(/(?:^|\s)@([^\s@#[\]]*)$/);
  return m ? { query: m[1], start: pos - m[1].length - 1, end: pos } : null;
}
function updateMention() {
  const ctx = mentionContext();
  if (!ctx) return closeMention();
  const q = ctx.query.toLowerCase();
  const items = flatVault(vaultTree, []).filter(n => n.path !== open.path && n.name.toLowerCase().includes(q)).slice(0, 8);
  if (!items.length) return closeMention();
  mentionRange = ctx; mentionItems = items; mentionSel = 0;
  renderMention();
}
function renderMention() {
  const pop = document.getElementById("mention");
  pop.innerHTML = mentionItems.map((n, i) =>
    `<button class="mitem ${i === mentionSel ? "sel" : ""}" data-i="${i}">${iconFor(n.type, (n.meta && n.meta.icon) || DEF_ICON[n.type], 15)}<span class="mn">${esc(n.name)}</span><span class="mk">${n.type}</span></button>`).join("");
  const c = caretCoords(proseEl);
  pop.style.left = Math.round(c.left) + "px";
  pop.style.top = Math.round(c.top + 20) + "px";
  pop.classList.add("on");
  refreshIcons();
  pop.querySelectorAll(".mitem").forEach(b => b.onmousedown = e => { e.preventDefault(); pickMention(+b.dataset.i); });
}
function moveMention(d) { mentionSel = (mentionSel + d + mentionItems.length) % mentionItems.length; renderMention(); }
function pickMention(i) {
  const n = mentionItems[i]; if (!n || !mentionRange) return;
  const ref = `[[${n.name}]] `;
  const v = proseEl.value;
  proseEl.value = v.slice(0, mentionRange.start) + ref + v.slice(mentionRange.end);
  const cur = mentionRange.start + ref.length;
  closeMention();
  proseEl.focus();
  proseEl.setSelectionRange(cur, cur);
  onEdit();   // mark dirty / live-save
}
function closeMention() { mentionRange = null; document.getElementById("mention").classList.remove("on"); }

proseEl.addEventListener("input", updateMention);
proseEl.addEventListener("keydown", e => {
  if (!document.getElementById("mention").classList.contains("on")) return;
  if (e.key === "ArrowDown") { e.preventDefault(); moveMention(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); moveMention(-1); }
  else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); pickMention(mentionSel); }
  else if (e.key === "Escape") { e.preventDefault(); closeMention(); }
});
proseEl.addEventListener("blur", () => setTimeout(closeMention, 150));
proseEl.addEventListener("scroll", () => mentionRange && closeMention());

// a [[ref]] behaves as ONE baked-in unit — backspace/delete removes the whole
// reference at once (you can't chip away at the brackets or the name inside)
proseEl.addEventListener("keydown", e => {
  if (proseEl.selectionStart !== proseEl.selectionEnd) return;
  const pos = proseEl.selectionStart, v = proseEl.value;
  if (e.key === "Backspace") {
    const m = v.slice(0, pos).match(/\[\[[^\[\]]*\]\]$/);
    if (m) { e.preventDefault(); const s = pos - m[0].length; proseEl.value = v.slice(0, s) + v.slice(pos); proseEl.setSelectionRange(s, s); onEdit(); }
  } else if (e.key === "Delete") {
    const m = v.slice(pos).match(/^\[\[[^\[\]]*\]\]/);
    if (m) { e.preventDefault(); proseEl.value = v.slice(0, pos) + v.slice(pos + m[0].length); proseEl.setSelectionRange(pos, pos); onEdit(); }
  }
});

// caret pixel position inside a textarea (mirror-div technique)
function caretCoords(ta) {
  const div = document.createElement("div"), cs = getComputedStyle(ta);
  ["fontFamily","fontSize","fontWeight","fontStyle","letterSpacing","textTransform","wordSpacing",
   "paddingTop","paddingRight","paddingBottom","paddingLeft","borderTopWidth","borderRightWidth",
   "borderBottomWidth","borderLeftWidth","lineHeight","boxSizing"].forEach(p => div.style[p] = cs[p]);
  Object.assign(div.style, { position: "absolute", visibility: "hidden", whiteSpace: "pre-wrap",
    wordWrap: "break-word", overflow: "hidden", width: ta.clientWidth + "px", top: "0", left: "0" });
  div.textContent = ta.value.slice(0, ta.selectionStart);
  const span = document.createElement("span"); span.textContent = "​"; div.appendChild(span);
  document.body.appendChild(div);
  const r = ta.getBoundingClientRect();
  const out = { left: r.left + span.offsetLeft - ta.scrollLeft, top: r.top + span.offsetTop - ta.scrollTop };
  document.body.removeChild(div);
  return out;
}

// ── the modal (ours, in-theme — never the system prompt). The new-file body is
// the default; askRename swaps in a raw body and restores after. ──────────────
// generic frame (also used by askRename): set body + show
function openModalRaw(html) {
  document.getElementById("modal").innerHTML = html;
  document.getElementById("shade").classList.add("on");
  document.getElementById("modal").classList.add("on");
  refreshIcons();
}
function closeModal() {
  document.getElementById("shade").classList.remove("on");
  document.getElementById("modal").classList.remove("on");
  closePop();
}
document.getElementById("shade").onclick = () => closeModal();

