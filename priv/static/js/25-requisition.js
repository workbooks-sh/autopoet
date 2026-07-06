// ── FORM AP-7: the AUTOPOET DEPARTMENT personality requisition ─────────────
// The first-run intake: a straight-faced interagency form that pairs the
// requester with their autopoet. Marks go to the pairing officer (the planner
// LLM via /onboard/requisition); the reply is the character — name, voice,
// assignment note — and plan mode later performs its custom intro diagram.
function showRequisition() {
  const onboard = document.getElementById("onboard");
  onboard.classList.remove("hidden");
  const inner = document.querySelector("#onboard .obinner");
  if (inner) inner.style.display = "none";
  ["obslides", "obsteps", "obquiz"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.style.display = "none";
  });

  let host = document.getElementById("obreq");
  if (host) host.remove();
  host = document.createElement("div");
  host.id = "obreq";
  const user = (typeof currentUser !== "undefined" && currentUser) || {};
  const fullName = user.name && user.name !== "demo" ? user.name : "";
  const today = new Date().toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });

  const CHECK = (name, opts) => opts.map(o =>
    `<label class="rq-ck"><input type="checkbox" name="${name}" value="${o}"><i></i>${o}</label>`).join("");
  const RADIO = (name, label, opts, def) => `
    <div class="rq-row"><span class="rq-lbl">${label}</span>
      ${opts.map(o => `<label class="rq-ck rq-rd"><input type="radio" name="${name}" value="${o}" ${o === def ? "checked" : ""}><i></i>${o}</label>`).join("")}
    </div>`;

  host.innerHTML = `
  <div class="rq-sheet">
    <div class="rq-head">
      <div class="rq-seal">AP</div>
      <div class="rq-agency">
        <b>AUTOPOET DEPARTMENT</b>
        <span>Bureau of Companion Provisioning · Form AP-7 (rev. 4)</span>
      </div>
      <div class="rq-omb">OMB No. 0042-AP<br>Expires: never</div>
    </div>
    <div class="rq-title">PERSONALITY REQUISITION</div>
    <div class="rq-sub">Please mark clearly. Your marks determine the poet you receive. There are no wrong answers, only consequential ones.</div>

    <div class="rq-sec"><b>A. REQUESTER</b>
      <div class="rq-row"><span class="rq-lbl">full name</span>
        <input id="rq-name" class="rq-line" type="text" value="${fullName.replace(/"/g, "&quot;")}" placeholder="print legibly"></div>
    </div>

    <div class="rq-sec"><b>B. PRIMARY DEPLOYMENT</b> <em>(mark all that apply)</em>
      <div class="rq-grid">${CHECK("areas", ["writing & research", "building software", "running a business", "personal operations", "learning things", "general mischief"])}</div>
    </div>

    <div class="rq-sec"><b>C. TEMPERAMENT SPECIFICATION</b>
      ${RADIO("manner", "bedside manner", ["gentle", "direct", "blunt"], "direct")}
      ${RADIO("energy", "energy", ["calm", "steady", "spirited"], "steady")}
      ${RADIO("humor", "humor", ["minimal", "dry", "mandatory"], "dry")}
      ${RADIO("verbosity", "verbosity", ["terse", "balanced", "storyteller"], "balanced")}
    </div>

    <div class="rq-sec"><b>D. VOICE PREFERENCE</b>
      ${RADIO("voice_pref", "timbre", ["warm", "bright", "deep", "smoky", "surprise me"], "surprise me")}
      ${RADIO("accent_pref", "accent", ["no preference", "british", "american", "southern", "australian"], "no preference")}
    </div>

    <div class="rq-sec"><b>E. REMARKS</b>
      <input id="rq-remarks" class="rq-line rq-wide" type="text" placeholder="anything the department should know (optional)">
    </div>

    <div class="rq-sig">
      <div><span class="rq-cursive" id="rq-sig">${fullName || "&nbsp;"}</span><label>signature of requester</label></div>
      <div><span>${today}</span><label>date</label></div>
    </div>
    <div class="rq-fine">By signing, the requester consents to being understood. The Department is not liable for attachment. Processing time: seconds, usually.</div>

    <div class="rq-actions">
      <div class="rq-stamp" id="rq-stamp"></div>
      <button id="rq-submit" class="rq-btn">SUBMIT REQUISITION →</button>
    </div>
  </div>`;
  onboard.appendChild(host);

  const nameEl = host.querySelector("#rq-name");
  nameEl.addEventListener("input", () => {
    host.querySelector("#rq-sig").textContent = nameEl.value || " ";
  });

  host.querySelector("#rq-submit").onclick = async () => {
    const btn = host.querySelector("#rq-submit");
    const stamp = host.querySelector("#rq-stamp");
    btn.disabled = true;
    stamp.className = "rq-stamp on";
    stamp.textContent = "PROCESSING";
    const form = {
      name: nameEl.value.trim(),
      areas: [...host.querySelectorAll('input[name="areas"]:checked')].map(i => i.value),
      manner: (host.querySelector('input[name="manner"]:checked') || {}).value,
      energy: (host.querySelector('input[name="energy"]:checked') || {}).value,
      humor: (host.querySelector('input[name="humor"]:checked') || {}).value,
      verbosity: (host.querySelector('input[name="verbosity"]:checked') || {}).value,
      voice_pref: (host.querySelector('input[name="voice_pref"]:checked') || {}).value,
      accent_pref: (host.querySelector('input[name="accent_pref"]:checked') || {}).value,
      remarks: host.querySelector("#rq-remarks").value.trim()
    };
    let identity = null;
    try {
      const r = await fetch("/onboard/requisition", {
        method: "POST",
        headers: { authorization: "Bearer " + TOKEN, "content-type": "application/json" },
        body: JSON.stringify(form)
      });
      if (r.ok) identity = await r.json();
    } catch (_) {}
    // the paired voice became the default — warm ITS engine now so the
    // entrance line meets a ready model
    fetch("/voices/default.json").then(r => r.json()).then(d => {
      const model = d && d.engine === "qwen-clone" ? "base" : "design";
      return fetch("/voice/tts/qwen/boot?model=" + model, { method: "POST",
        headers: { authorization: "Bearer " + TOKEN } });
    }).catch(() => {});
    if (identity && identity.name) {
      stamp.className = "rq-stamp on ok";
      stamp.textContent = "APPROVED";
      const note = document.createElement("div");
      note.className = "rq-note";
      note.textContent = `assignment: ${identity.name} · voice: ${identity.voice} — ${identity.blurb || ""}`;
      btn.replaceWith(note);
      setTimeout(() => { host.remove(); showPower(); }, 2600);
    } else {
      // the department never loses a form — proceed regardless
      stamp.className = "rq-stamp on ok";
      stamp.textContent = "FILED";
      setTimeout(() => { host.remove(); showPower(); }, 1200);
    }
  };
}
