// ── onboarding / sign-in gate (stub auth; real provider slots in behind Autopoet.Auth) ──
function hideOnboard() { document.getElementById("onboard").classList.add("hidden"); }
function showSignIn() {
  document.getElementById("onboard").classList.remove("hidden");
  document.getElementById("obsteps").style.display = "none";
  document.querySelector("#onboard .obinner").style.display = "flex";
  mountOnboardFace();
  refreshIcons();
}
// the splash avatar is the SAME face component, scoped so it runs independently
let _obFaceMounted = false;
async function mountOnboardFace() {
  const box = document.getElementById("obface");
  if (!box || _obFaceMounted) return;
  _obFaceMounted = true;
  // Prefer the SAME avatar as the running app + the website: the 3D WebGL cube
  // (avatar3d.mjs — real mesh + inverted-hull toon outline) with the DOM face
  // overlay glued on. Wait briefly for the module; if WebGL/three isn't ready,
  // fall back to the flat 2D face so login is never left blank.
  for (let i = 0; i < 40 && !window.Avatar3D; i++) await new Promise(r => setTimeout(r, 50));
  if (!window.Avatar3D) { createFace(box, { idPrefix: "ob" }); return; }
  box.innerHTML = "";
  box.style.border = "none"; box.style.background = "transparent";
  box.style.position = "relative"; box.style.overflow = "visible";
  const host = document.createElement("div");
  host.className = "cube-host";
  const scale = (box.offsetWidth || 72) / 132;        // native cube is 132px
  host.style.cssText = `position:absolute;left:50%;top:50%;width:132px;height:132px;` +
    `transform:translate(-50%,-50%) scale(${scale});`;
  host.innerHTML = '<div class="sc-cube"><div class="sc-face"></div></div>';
  box.appendChild(host);
  const cube = host.firstChild, face = cube.firstChild;
  try { host._avatar3d = Avatar3D.mount(host, cube); } catch (_) {}
  await createFace(face, { idPrefix: "ob", hoverTarget: cube, clickTarget: cube });
  // gentle idle breathing so the login cube feels alive like the app's
  let bt = 0;
  setInterval(() => { bt += 0.09;
    cube.style.setProperty("--br", (Math.sin(bt * 2 * Math.PI / 4) * 0.7).toFixed(2) + "deg"); }, 90);
}
// the cold-start flow: sign UP lands here — (1) it asks your name, (2) it explains
// the one-way loop (vault → translation → proposals), then drops you into the app.
function showOnboardSteps() {
  const ob = document.getElementById("onboard");
  ob.classList.remove("hidden");
  document.querySelector("#onboard .obinner").style.display = "none";
  document.getElementById("obsteps").style.display = "flex";
  obStep(1);
}
function obStep(n) {
  const s = document.getElementById("obsteps");
  if (n === 1) {
    s.innerHTML = `<div class="obsface" id="obsface"></div>
      <div class="obword" style="font-size:24px">hello.</div>
      <p class="obtext" style="margin:0">I keep a living body of structure grown from your
        notes — your plain words become real, running form. Before we begin: what
        should I call you?</p>
      <input id="ob-name" class="obinput" placeholder="your name" maxlength="40" spellcheck="false">
      <button class="obstepgo" id="ob-next">continue</button>`;
    createFace(document.getElementById("obsface"), { idPrefix: "obs" });
    const input = document.getElementById("ob-name");
    if (currentUser && currentUser.name && currentUser.name !== "demo") input.value = currentUser.name;
    const go = () => {
      const name = input.value.trim();
      if (!name) { input.focus(); return; }
      authedPost("/auth/signup?name=" + encodeURIComponent(name)).then(() => obStep(3));
    };
    document.getElementById("ob-next").onclick = go;
    input.addEventListener("keydown", e => { if (e.key === "Enter") go(); });
    setTimeout(() => input.focus(), 50);
  } else if (n === 2) {
    obConnectStep();
  } else {
    showSlides();
  }
}
// step 2 — CONNECTIONS: you signed in with one; connect both if you want. What's
// connected decides where the work lives (GitHub monorepo vs local git + Drive).
const OB_GH_SVG = `<svg viewBox="0 0 16 16" width="22" height="22" aria-hidden="true"><path fill="#1c2230" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8"/></svg>`;
const OB_GOO_SVG = `<svg viewBox="0 0 18 18" width="22" height="22" aria-hidden="true"><path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62z"/><path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.33A9 9 0 0 0 9 18z"/><path fill="#FBBC05" d="M3.97 10.72a5.41 5.41 0 0 1 0-3.44V4.95H.96a9 9 0 0 0 0 8.1l3.01-2.33z"/><path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58C13.46.9 11.42 0 9 0A9 9 0 0 0 .96 4.95l3.01 2.33C4.68 5.16 6.66 3.58 9 3.58z"/></svg>`;
const OB_CF_SVG = `<img src="data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPkNsb3VkZmxhcmU8L3RpdGxlPjxwYXRoIGQ9Ik0xNi40OTMgMTcuNGMuMTM1LS41Mi4wOC0uOTgzLS4xNjEtMS4zMzgtLjIxNS0uMzI4LS41OTItLjUxOS0xLjA1LS41MTlsLTguNjYzLS4xMDlhLjE0OC4xNDggMCAwMS0uMTM1LS4wODJjLS4wMjctLjA1NC0uMDI3LS4xMDktLjAyNy0uMTYzLjAyNy0uMDgyLjEwOC0uMTY0LjE4OS0uMTY0bDguNzQ0LS4xMWMxLjA1LS4wNTQgMi4xNTMtLjkgMi41NTYtMS45MzdsLjUxMS0xLjMxYy4wMjctLjA1NS4wMjctLjExLjAyNy0uMTY0QzE3LjkyIDguOTEgMTUuNjYgNyAxMi45NDIgN2MtMi41MDMgMC00LjYyOCAxLjYzOC01LjM4MSAzLjkwM2EyLjQzMiAyLjQzMiAwIDAwLTEuODAzLS40OTFjLTEuMjEuMTA5LTIuMTUzIDEuMDkyLTIuMjg3IDIuMzItLjAyNy4zMjggMCAuNjI4LjA1NC45QzEuNTYgMTMuNjg4IDAgMTUuMzI2IDAgMTcuMzE5YzAgLjE5LjAyNy4zNTUuMDI3LjU0NSAwIC4wODIuMDguMTM3LjE2MS4xMzdoMTUuOTgzYy4wOCAwIC4xODgtLjA1NS4yMTUtLjE2NGwuMTA3LS40MzciIGZpbGw9IiNGMzgwMjAiPjwvcGF0aD48cGF0aCBkPSJNMTkuMjM4IDExLjc1aC0uMjQyYy0uMDU0IDAtLjEwOC4wNTQtLjEzNS4xMDlsLS4zNSAxLjJjLS4xMzQuNTItLjA4Ljk4My4xNjIgMS4zMzguMjE1LjMyOC41OTIuNTE4IDEuMDUuNTE4bDEuODU1LjExYy4wNTQgMCAuMTA4LjAyNy4xMzUuMDgyLjAyNy4wNTQuMDI3LjEwOS4wMjcuMTYzLS4wMjcuMDgyLS4xMDguMTY0LS4xODguMTY0bC0xLjkxLjExYy0xLjA1LjA1NC0yLjE1My45LTIuNTU3IDEuOTM3bC0uMTM0LjM1NWMtLjAyNy4wNTUuMDI2LjEzNy4xMDcuMTM3aDYuNTkyYy4wODEgMCAuMTYyLS4wNTUuMTYyLS4xMzcuMTA3LS40MS4xODgtLjg0Ni4xODgtMS4zMS0uMDI3LTIuNjItMi4xNTMtNC43NzctNC43NjItNC43NzciIGZpbGw9IiNGQ0FEMzIiPjwvcGF0aD48L3N2Zz4=" width="22" height="22" alt="" style="object-fit:contain">`;
const OB_POLAR_SVG = `<img src="data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyBpZD0iTGF5ZXJfMSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB4bWxuczp4bGluaz0iaHR0cDovL3d3dy53My5vcmcvMTk5OS94bGluayIgdmVyc2lvbj0iMS4xIiB2aWV3Qm94PSIwIDAgMzAwIDMwMCI+CiAgPCEtLSBHZW5lcmF0b3I6IEFkb2JlIElsbHVzdHJhdG9yIDI5LjMuMSwgU1ZHIEV4cG9ydCBQbHVnLUluIC4gU1ZHIFZlcnNpb246IDIuMS4wIEJ1aWxkIDE1MSkgIC0tPgogIDxkZWZzPgogICAgPHN0eWxlPgogICAgICAuc3QwIHsKICAgICAgICBmaWxsOiBub25lOwogICAgICB9CgogICAgICAuc3QxIHsKICAgICAgICBmaWxsLXJ1bGU6IGV2ZW5vZGQ7CiAgICAgIH0KCiAgICAgIC5zdDIgewogICAgICAgIGNsaXAtcGF0aDogdXJsKCNjbGlwcGF0aCk7CiAgICAgIH0KICAgIDwvc3R5bGU+CiAgICA8Y2xpcFBhdGggaWQ9ImNsaXBwYXRoIj4KICAgICAgPHJlY3QgY2xhc3M9InN0MCIgd2lkdGg9IjMwMCIgaGVpZ2h0PSIzMDAiLz4KICAgIDwvY2xpcFBhdGg+CiAgPC9kZWZzPgogIDxnIGNsYXNzPSJzdDIiPgogICAgPHBhdGggY2xhc3M9InN0MSIgZD0iTTY2LjQsMjc0LjNjNjguNCw0Ni4zLDE2MS41LDI4LjQsMjA3LjgtNDAsNDYuMy02OC40LDI4LjQtMTYxLjUtNDAtMjA3LjhDMTY1LjgtMTkuOSw3Mi43LTIsMjYuNCw2Ni40LTE5LjksMTM0LjktMiwyMjcuOSw2Ni40LDI3NC4zWk00OCwxMTYuN2MtMTcuMSw1Mi42LTExLjQsMTA1LjIsMTEuMywxMzkuN0MxOCwyMTcuNCw3LjMsMTUwLjMsMzYuOSw5Mi4zLDU1LjksNTUuMiw4Ny42LDI5LjQsMTIyLjUsMTguM2MtMzEuOSwxOC40LTU5LjksNTMuNS03NC41LDk4LjNaTTE3NS4zLDI4My4xYzM2LTEwLjUsNjguOS0zNi44LDg4LjMtNzQuOCwyOS40LTU3LjUsMTkuMS0xMjMuOS0yMS4zLTE2My4xLDIxLjgsMzQuNSwyNyw4Ni4zLDEwLjIsMTM4LTE1LDQ2LjEtNDQuMiw4Mi03Ny4zLDk5LjhaTTE4My42LDI2Ni4yYzI0LjMtMjAuOCw0NC40LTU1LjYsNTMuMy05Ny40LDE0LjEtNjYuMS00LjQtMTI3LjYtNDEuOC0xNDguMSwxOS45LDI2LjcsMjkuOSw3OC42LDIzLjcsMTM2LjctNC43LDQ0LjQtMTgsODMuMy0zNS4yLDEwOC45Wk02My43LDEzMS44Yy0xNC4yLDY2LjYsNC43LDEyOC41LDQyLjcsMTQ4LjYtMjAuNC0yNi40LTMwLjgtNzguOS0yNC41LTEzNy43LDQuNy00My43LDE3LjYtODIsMzQuMy0xMDcuNi0yNCwyMC45LTQzLjcsNTUuNC01Mi41LDk2LjdaTTE5OS44LDE0OS42YzEuMSw2Ny45LTIwLjIsMTIzLjMtNDcuNiwxMjMuNy0yNy40LjQtNTAuNC01NC4zLTUxLjUtMTIyLjItMS4xLTY3LjksMjAuMi0xMjMuMyw0Ny42LTEyMy43LDI3LjQtLjQsNTAuNCw1NC4zLDUxLjUsMTIyLjJaIi8+CiAgPC9nPgo8L3N2Zz4=" width="22" height="22" alt="" style="object-fit:contain">`;
const OB_STRIPE_SVG = `<img src="data:image/png;base64,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" width="30" height="22" alt="" style="object-fit:contain">`;
const OB_OR_SVG = `<img src="data:image/svg+xml;base64,PHN2ZyBmaWxsPSIjNjQ2N2YyIiBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGhlaWdodD0iMWVtIiBzdHlsZT0iZmxleDpub25lO2xpbmUtaGVpZ2h0OjEiIHZpZXdCb3g9IjAgMCAyNCAyNCIgd2lkdGg9IjFlbSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+T3BlblJvdXRlcjwvdGl0bGU+PHBhdGggZD0iTTE2LjgwNCAxLjk1N2w3LjIyIDQuMTA1di4wODdMMTYuNzMgMTAuMjFsLjAxNy0yLjExNy0uODIxLS4wM2MtMS4wNTktLjAyOC0xLjYxMS4wMDItMi4yNjguMTEtMS4wNjQuMTc1LTIuMDM4LjU3Ny0zLjE0NyAxLjM1Mkw4LjM0NSAxMS4wM2MtLjI4NC4xOTUtLjQ5NS4zMzYtLjY4LjQ1NWwtLjUxNS4zMjItLjM5Ny4yMzQuMzg1LjIzLjUzLjMzOGMuNDc2LjMxNCAxLjE3Ljc5NiAyLjcwMSAxLjg2NiAxLjExLjc3NSAyLjA4MyAxLjE3NyAzLjE0NyAxLjM1MmwuMy4wNDVjLjY5NC4wOTEgMS4zNzUuMDk0IDIuODI1LjAzM2wuMDIyLTIuMTU5IDcuMjIgNC4xMDV2LjA4N0wxNi41ODkgMjJsLjAxNC0xLjg2Mi0uNjM1LjAyMmMtMS4zODYuMDQyLTIuMTM3LjAwMi0zLjEzOC0uMTYyLTEuNjk0LS4yOC0zLjI2LS45MjYtNC44ODEtMi4wNTlsLTIuMTU4LTEuNWEyMS45OTcgMjEuOTk3IDAgMDAtLjc1NS0uNDk4bC0uNDY3LS4yOGE1NS45MjcgNTUuOTI3IDAgMDAtLjc2LS40M0MyLjkwOCAxNC43My41NjMgMTQuMTE2IDAgMTQuMTE2VjkuODg4bC4xNC4wMDRjLjU2NC0uMDA3IDIuOTEtLjYyMiAzLjgwOS0xLjEyNGwxLjAxNi0uNTguNDM4LS4yNzRjLjQyOC0uMjggMS4wNzItLjcyNiAyLjY4Ni0xLjg1MyAxLjYyMS0xLjEzMyAzLjE4Ni0xLjc4IDQuODgxLTIuMDU5IDEuMTUyLS4xOSAxLjk3NC0uMjEzIDMuODE0LS4xMzhsLjAyLTEuOTA3eiI+PC9wYXRoPjwvc3ZnPg==" width="22" height="22" alt="" style="object-fit:contain">`;
const OB_WB_SVG = `<img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMTMuNDQ0IDY1LjYiPjxwYXRoIGZpbGw9IiMwMDAiIGQ9Ik00OC4yNzEgMC4xMzdDNTQuMDM1LTAuMDQyIDU5LjQ4Ni0wLjEgNjUuMjM5IDAuMzA4YzAuMjkxIDkuNzcyLTAuMDY0IDE5LjY1NCAwLjIyMyAyOS40MyAwLjAyNSAwLjgzIDAuNDA5IDEuNDA0IDAuOTI5IDIuMDA1IDUuNzE3IDEuNzIxIDE4LjM2MS0xNy44OTggMjQuNTMtMjAuMDAzIDIuOTg2IDAuNjA0IDkuMTY2IDguMjU4IDExLjM1MiAxMC43MTctMy41NDMgNS45Ni0xOSAxOC4yMzQtMjAuODkxIDIyLjU0NiAwLjAxOCAxLjI4NCAwLjA2OCAxLjMyMiAwLjc3NSAyLjQzOSAxLjU1IDEuMTk1IDI2LjA5NSAwLjU0NSAzMC45NzYgMS4wMjIgMC40MzcgNS41MiAwLjI5OCAxMS40IDAuMjU4IDE2Ljk2NC0xMS43MjEgMC4wMi0yNi43MTIgMS4zNTItMzYuOTE4LTMuNzM4LTguNDI0LTQuMTYzLTE0LjgyMy0xMS41MzEtMTcuNzY5LTIwLjQ1Mi0wLjc2NS0yLjY1My0xLjMxNy01LjA4OC0xLjkyNC03Ljc3MS0xLjE4MSA1LjIzMy0yLjEwMyA5LjUyLTQuODU5IDE0LjIzOC0xMi4xMTcgMjAuNzM2LTMxLjY5MyAxNy43NS01MS44NTYgMTcuNjgzLTAuMDU4LTUuNzQzLTAuMDA2LTExLjQ4OCAwLjIyMi0xNy4yMjggNS4yOS0wLjAyNSAyOC4yMDMgMC41ODEgMzEuNDc3LTAuODkgMC4xNjMtMC4zNzQgMC4yMDYtMC40MjIgMC4yODgtMC44NjYgMC42ODUtMy43MjMtMTcuNDI5LTE5LjA1NS0yMC4zNjgtMjMuNTY2bC0wLjI0Ni0wLjM4MmMxLjgwNC0yLjU0OSA3Ljk3NC05LjM4MyAxMC42OS0xMC42ODMgMy43MjgtMC41NjMgMTcuOTM5IDE4LjA1NyAyMi4zOTMgMTkuOTE1IDEuMzg5IDAuNTc5IDEuNjEyIDAuNTQyIDIuODM1IDAuMDYyIDEuMzc1LTEuOTUzIDAuOTE1LTguOTMgMC45MjYtMTEuNTk4TDQ4LjI3MSAwLjEzN1oiLz48L3N2Zz4K" width="24" height="18" alt="" style="object-fit:contain">`;
const OB_GMAIL_SVG = `<svg viewBox="0 0 48 48" width="13" height="13" style="vertical-align:-2px" aria-hidden="true"><path fill="#4caf50" d="M45 16.2l-4 3-4 3v12h6c1.1 0 2-.9 2-2V16.2z"/><path fill="#1e88e5" d="M3 16.2l4 3 4 3v12H5c-1.1 0-2-.9-2-2V16.2z"/><path fill="#e53935" d="M35 11.2l-11 8.25L13 11.2 12 17l1 5.2 11 8.25 11-8.25 1-5.2z"/><path fill="#c62828" d="M3 12.3v3.9l10 6V11.2L9.88 8.86C9.13 8.3 8.23 8 7.3 8 4.92 8 3 9.92 3 12.3z"/><path fill="#fbc02d" d="M45 12.3v3.9l-10 6V11.2l3.12-2.34C38.87 8.3 39.77 8 40.7 8c2.38 0 4.3 1.92 4.3 4.3z"/></svg>`;
async function obConnectStep() {
  const s = document.getElementById("obsteps");
  let conns = {};
  try { conns = (await (await fetch("/auth/state.json")).json()).connections || {}; } catch (_) {}
  s.innerHTML = `<div class="obword" style="font-size:24px">connect</div>
    <p class="obtext" style="margin:0">You signed in with one — connect any of these.
      Together they decide what the autopoet can do for you.</p>
    <div class="obcards">
      <div class="obcard" data-prov="github">
        <span class="oblogo">${OB_GH_SVG}</span><span class="obcardname">GitHub</span>
        <span class="obcardline">a monorepo it keeps and syncs for you</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
      <div class="obcard" data-prov="google">
        <span class="oblogo">${OB_GOO_SVG}</span><span class="obcardname">Google</span>
        <span class="obcardline">Workspace as context; Drive as backup</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
      <div class="obcard" data-prov="cloudflare">
        <span class="oblogo">${OB_CF_SVG}</span><span class="obcardname">Cloudflare</span>
        <span class="obcardline">publish your weaved sites to the web</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
      <div class="obcard" data-prov="openrouter">
        <span class="oblogo">${OB_OR_SVG}</span><span class="obcardname">OpenRouter</span>
        <span class="obcardline">its own AI, any model, on your credits</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
      <div class="obcard" data-prov="polar">
        <span class="oblogo">${OB_POLAR_SVG}</span><span class="obcardname">Polar</span>
        <span class="obcardline">it sets up products &amp; checkouts</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
      <div class="obcard" data-prov="cloud" id="ob-cloud-card">
        <span class="oblogo">${OB_WB_SVG}</span><span class="obcardname">Workbooks Cloud</span>
        <span class="obcardline">run in the cloud · connect any tool</span>
        <span class="obck"><i data-lucide="check"></i></span>
      </div>
    </div>
    <div class="obabil" id="obplan"></div>
    <button class="obstepgo" id="ob-next2">continue</button>`;
  // the ABILITIES card: a compact comparison — every ability listed, checked or
  // not by the exact combination connected
  const plan = () => {
    const abilities = [
      ["local git history", true, "built in"],
      ["synced GitHub monorepo", !!conns.github, "github"],
      ["Workspace — Gmail, Docs, Sheets, Drive", !!conns.google, "google"],
      ["publish sites to the web", !!conns.cloudflare, "cloudflare"],
      ["its own AI inference, any model", !!conns.openrouter, "openrouter"],
      ["sell products & take payments", !!conns.polar, "polar"]
    ];
    document.getElementById("obplan").innerHTML = abilities.map(([label, on, src]) =>
      `<div class="abrow${on ? " on" : ""}">
         <span class="abck"><i data-lucide="${on ? "check" : "x"}"></i></span>
         <span class="ablabel">${label}</span>
         <span class="absrc">${src}</span>
       </div>`).join("");
    refreshIcons();
  };
  const paint = () => {
    for (const card of s.querySelectorAll(".obcard"))
      card.classList.toggle("on", !!conns[card.dataset.prov]);
    plan();
  };
  // refresh connection truth from the server (real, token-backed)
  const refresh = async () => {
    try { conns = (await (await fetch("/auth/state.json")).json()).connections || {}; } catch (_) {}
    try { conns.cloud = !!(await (await fetch("/cloud/status.json")).json()).signed_in; } catch (_) {}
    paint();
  };
  // a connected card DISCONNECTS on click; an unconnected one runs the REAL flow:
  // github/google open the system browser to the OAuth login; cloudflare takes a
  // pasted, user-scoped API token (it has no consumer OAuth).
  for (const card of s.querySelectorAll(".obcard"))
    card.onclick = async () => {
      const prov = card.dataset.prov;
      // Workbooks Cloud isn't an OAuth provider — it's our own cloud host, still
      // being built. Your app toolbelt is chosen in setup; this card is the
      // "run in the cloud" half, coming soon.
      if (prov === "cloud") {
        // signed in → disconnect on click; otherwise open the browser device flow + poll
        if (conns.cloud) {
          await authedPost("/auth/cloud/disconnect");
          conns.cloud = false; paint();
          toast("disconnected from workbooks cloud");
          return;
        }
        await authedPost("/auth/cloud/open");
        card.classList.add("pending");
        toast("finish sign-in in your browser…");
        pollCloud();
        return;
      }
      if (conns[prov]) {
        await authedPost("/auth/disconnect/" + prov);
        conns[prov] = false;
        paint();
        return;
      }
      // all three run real OAuth now: open the SYSTEM browser (WKWebView can't
      // host Google's OAuth), then poll for the connection. The callback tab also
      // postMessages back as a fast-path when the flow runs in this same browser.
      // (Cloudflare still accepts a pasted API token via /auth/cloudflare/token
      // for power users, but the card default is the real OAuth flow.)
      await authedPost("/auth/" + prov + "/open");
      card.classList.add("pending");
      pollFor(prov);
    };
  // poll /auth/state.json until the provider connects (or give up after ~2min)
  let _poll = null;
  const pollFor = prov => {
    clearInterval(_poll);
    let tries = 0;
    _poll = setInterval(async () => {
      tries++;
      try {
        const c = (await (await fetch("/auth/state.json")).json()).connections || {};
        if (c[prov] || tries > 60) {
          clearInterval(_poll);
          conns = c;
          for (const el of s.querySelectorAll(".obcard")) el.classList.remove("pending");
          paint();
        }
      } catch (_) {}
    }, 2000);
  };
  // poll cloud sign-in status until the browser device flow completes
  const pollCloud = () => {
    clearInterval(_poll);
    let tries = 0;
    _poll = setInterval(async () => {
      tries++;
      try {
        const st = await (await fetch("/cloud/status.json")).json();
        if (st.signed_in || tries > 90) {
          clearInterval(_poll);
          conns.cloud = !!st.signed_in;
          for (const el of s.querySelectorAll(".obcard")) el.classList.remove("pending");
          paint();
          if (st.signed_in) toast("connected to workbooks cloud");
        }
      } catch (_) {}
    }, 2000);
  };
  // fast-path: a same-browser callback postMessages back (OAuth or cloud device flow)
  addEventListener("message", e => { if (e.data && (e.data.apOauth || e.data.apCloud)) refresh(); });
  refresh();
  refreshIcons();
  document.getElementById("ob-next2").onclick = () => obStep(3);
}

