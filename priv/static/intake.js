// IntakeProposal — the proposal-first dashboard entry (Lane D).
//
// On first load after onboarding, if the intake agent left a pending proposal,
// the app opens ON it: the brief on top, the LIVING graph visible behind.
// Three doors: accept (the workspace lands in the vault, via the existing
// gated accept), "let me look around" (stays pending in the proposals inbox),
// or reject with a note. app.html calls IntakeProposal.check(hooks) once the
// authed+onboarded state is known.
(() => {
  const CSS = `
  #intakeveil { position:fixed; inset:0; z-index:55; display:flex; align-items:center;
    justify-content:center; background:rgba(24,28,38,.28); backdrop-filter:blur(2px);
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .ipcard { width:560px; max-height:76vh; display:flex; flex-direction:column; gap:14px;
    background:#fff; border:1px solid #d6dbe2; border-radius:18px; padding:22px 24px;
    box-shadow:0 24px 80px rgba(25,35,55,.25); }
  .ipkicker { font:10.5px ui-monospace,monospace; color:#b3bac4; letter-spacing:.08em; }
  .ipbody { overflow-y:auto; font:12px/1.7 ui-monospace,monospace; color:#2c3442;
    white-space:pre-wrap; border:1px solid #eef1f5; border-radius:12px;
    padding:14px 16px; background:#fafbfc; }
  .ipbody h { font-weight:600; color:#1c2230; }
  .iprow { display:flex; gap:10px; align-items:center; }
  .ipgo { font:12.5px ui-monospace,monospace; padding:9px 18px; border-radius:10px;
    border:1px solid #2f6fdd; background:#2f6fdd; color:#fff; cursor:pointer; }
  .ipgo:hover { background:#245cc0; }
  .ipquiet { font:11.5px ui-monospace,monospace; color:#67707c; background:none;
    border:none; cursor:pointer; }
  .ipquiet:hover { color:#1c2230; }
  .ipreject { margin-left:auto; }
  .ipnote { display:none; gap:8px; }
  .ipnote input { flex:1; font:12px ui-monospace,monospace; padding:8px 11px;
    border:1px solid #d6dbe2; border-radius:9px; outline:none; }
  .ipnote input:focus { border-color:#8e7cc3; }
  `;

  // the brief is markdown-ish plain text; render headers bold, keep the rest raw
  const render = text =>
    text
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/^#+ (.*)$/gm, "<h>$1</h>")
      .replace(/\*\*(.+?)\*\*/g, "<h>$1</h>")
      .replace(/\[\[(.+?)\]\]/g, "$1");

  async function check(hooks) {
    let id, brief;
    try {
      const r = await fetch("/intake/proposal");
      if (!r.ok) return;
      const text = await r.text();
      const nl = text.indexOf("\n");
      id = text.slice(0, nl).trim();
      brief = text.slice(nl + 1);
    } catch (_) { return; }
    if (!id) return;

    if (!document.getElementById("ipcss")) {
      const st = document.createElement("style");
      st.id = "ipcss"; st.textContent = CSS;
      document.head.appendChild(st);
    }

    const veil = document.createElement("div");
    veil.id = "intakeveil";
    veil.innerHTML = `
      <div class="ipcard">
        <div class="ipkicker">the autopoet filed its first work — this is a proposal, not a fait accompli</div>
        <div class="ipbody">${render(brief)}</div>
        <div class="ipnote"><input placeholder="what's wrong with it? (optional)"><button class="ipquiet" id="ipconfirm">reject it</button></div>
        <div class="iprow">
          <button class="ipgo" id="ipaccept">accept the plan</button>
          <button class="ipquiet" id="iplook">let me look around first</button>
          <button class="ipquiet ipreject" id="ipno">not like this</button>
        </div>
      </div>`;
    document.body.appendChild(veil);
    if (window.gsap) {
      gsap.from(veil.querySelector(".ipcard"), { y: 18, autoAlpha: 0, duration: .45, ease: "power2.out" });
    }

    const gone = () => veil.remove();
    veil.querySelector("#ipaccept").onclick = async () => {
      await hooks.post(`/proposal/${id}/accept`);
      location.reload();
    };
    veil.querySelector("#iplook").onclick = gone; // stays pending in the inbox
    veil.querySelector("#ipno").onclick = () => {
      veil.querySelector(".ipnote").style.display = "flex";
      veil.querySelector(".ipnote input").focus();
    };
    veil.querySelector("#ipconfirm").onclick = async () => {
      const reason = veil.querySelector(".ipnote input").value.trim();
      await hooks.post(`/proposal/${id}/reject?reason=${encodeURIComponent(reason)}`);
      gone();
    };
  }

  window.IntakeProposal = { check };
})();
