// ── VOICE SWITCHER (dev) — simplified to the owner's spec: pick a voice,
// restart the onboarding flow from the first slide IN that voice. That's it.
// (The behavior sliders/fire-buttons era lives in git history.)
window.BehaviorLab = (() => {
  let panel = null, traits = null;

  function attach(_verbs) {}   // kept for planmode's call-site compatibility

  async function toggle() {
    if (panel) return close();
    if (!traits) traits = await (await fetch("/voices/traits.json")).json();
    panel = document.createElement("div");
    panel.id = "blab";
    panel.innerHTML = `
      <div class="bl-hd"><b>voice</b><button id="bl-x">✕</button></div>
      <select id="bl-voice">${Object.keys(traits).sort().map(n => `<option>${n}</option>`).join("")}</select>
      <div class="bl-row"><button id="bl-go">restart onboarding in this voice ▸</button></div>
      <div class="bl-note" id="bl-note"></div>`;
    document.body.appendChild(panel);
    panel.querySelector("#bl-x").onclick = close;

    panel.querySelector("#bl-go").onclick = async () => {
      const sel = panel.querySelector("#bl-voice");
      const kind = (traits[sel.value] || {}).kind;
      const engine = kind === "pinned" ? "qwen-clone" : "qwen-design";
      const note = panel.querySelector("#bl-note");
      note.textContent = "setting default + warming…";
      const r = await fetch(`/voices/default?engine=${engine}&name=${sel.value}`, { method: "POST",
        headers: { authorization: "Bearer " + TOKEN } });
      if (!r.ok) { note.textContent = "couldn't set that voice"; return; }
      // wait for the engine, then restart plan mode from the top in this voice
      (function poll() {
        fetch("/voice/tts/qwen/status").then(x => x.text()).then(st => {
          if (st.trim() !== "ready") return setTimeout(poll, 800);
          note.textContent = "restarting…";
          try { PlanMode.teardown(); } catch (_) {}
          close();
          showPlanMode();
        }).catch(() => setTimeout(poll, 800));
      })();
    };
  }

  function close() {
    if (panel) { panel.remove(); panel = null; }
  }

  return { attach, toggle, close };
})();
