// ── the slide deck: a GSAP-animated walkthrough, the face card as centerpiece.
// Skippable; arrows (buttons + keyboard) navigate; the deck tweens BETWEEN slide
// states and each slide runs its own little scene animation. ──
const fxEl = html => { const d = document.createElement("div"); d.innerHTML = html; return d.firstElementChild; };
const fxIn = (els, d = 0) =>
  gsap.from(els, { autoAlpha: 0, y: 14, duration: .5, delay: d, stagger: .12, ease: "power2.out" });
const SLIDES = [
  { title: "meet the autopoet", mood: "happy",
    sub: "a self-authoring system. it reads what you mean — and makes what it means.",
    fx(fx) {
      const a = fxEl(`<div class="fxchip" style="left:17%;top:24%">/ˌɔː·toʊ·ˈpoʊ·ɪt/</div>`);
      const b = fxEl(`<div class="fxchip" style="right:15%;bottom:22%">// autopoiesis</div>`);
      fx.append(a, b);
      fxIn([a, b], .2);
      gsap.to([a, b], { y: "-=7", duration: 2.2, ease: "sine.inOut", yoyo: true, repeat: -1, stagger: .4, delay: .8 });
    } },
  { title: "a darwin gödel machine", mood: "hopeful",
    sub: "it improves by evolution — spawn variants of its own body, keep the survivor, rewrite again.",
    fx(fx) {
      // LEFT — the lineage the loop walks
      const lineage = fxEl(`<div class="fxchat" style="left:1%;top:16%;width:152px;align-items:center">
        <div style="display:flex;gap:12px">
          <div class="fxperson"><img class="fxpimg" src="/static/people/darwin.jpg" alt="">darwin</div>
          <div class="fxperson"><img class="fxpimg" src="/static/people/godel.jpg" alt="">gödel</div>
        </div>
        <div class="fxtool"><i data-lucide="dna"></i>self-rewriting agents</div>
      </div>`);
      // RIGHT — evolution, live: the parent spawns two variants, the survivor
      // takes the slot, forever. (this IS the loop, not a diagram of it)
      const stage = fxEl(`<div style="position:absolute;right:0;top:0;width:172px;height:100%"></div>`);
      const cred = fxEl(`<div class="fxcred"><img src="/static/people/hut.jpg" alt=""><img src="/static/people/merkle.png" alt=""><img src="/static/people/rivest.jpg" alt=""><span>running on barnes–hut · merkle · rivest</span></div>`);
      fx.append(lineage, stage, cred);
      refreshIcons();
      gsap.from(lineage.querySelectorAll(".fxperson"), { scale: 0, duration: .5, delay: .3, stagger: .18, ease: "back.out(2.5)" });
      gsap.from(lineage.querySelector(".fxtool"), { autoAlpha: 0, y: 8, duration: .4, delay: .75 });
      gsap.from(cred, { autoAlpha: 0, duration: .6, delay: 1.4 });
      const EVO_MOUTHS = [
        `<path d="M14 25 h12" stroke="#1c2230" stroke-width="2" stroke-linecap="round" fill="none"/>`,
        `<path d="M14 24 q6 6 12 0" stroke="#1c2230" stroke-width="2" stroke-linecap="round" fill="none"/>`,
        `<path d="M14 27 q6 -6 12 0" stroke="#1c2230" stroke-width="2" stroke-linecap="round" fill="none"/>`,
        `<circle cx="20" cy="25" r="3" stroke="#1c2230" stroke-width="2" fill="none"/>`,
        `<path d="M13 25 l3.5 -2.5 3.5 2.5 3.5 -2.5 3.5 2.5" stroke="#1c2230" stroke-width="2" stroke-linejoin="round" fill="none"/>`
      ];
      const face = m => `<svg viewBox="0 0 40 40" width="30" height="30" fill="none">
        <circle cx="14.5" cy="16" r="1.8" fill="#1c2230"/><circle cx="25.5" cy="16" r="1.8" fill="#1c2230"/>${m}</svg>`;
      const P = [67, 26], K1 = [22, 128], K2 = [112, 128];
      let alive = true;
      const pending = [];
      const later = (t, f) => pending.push(gsap.delayedCall(t, f));
      function cycle(parentMouth) {
        if (!alive) return;
        gsap.killTweensOf(stage.querySelectorAll("*"));
        stage.innerHTML = `<svg style="position:absolute;left:0;top:0" viewBox="0 0 172 230" width="172" height="230" fill="none">
          <path class="eb" d="M${P[0] + 19} ${P[1] + 38} C ${P[0] + 19} 100 ${K1[0] + 19} 92 ${K1[0] + 19} ${K1[1]}" stroke="#d9c9f0" stroke-width="1.6"/>
          <path class="eb" d="M${P[0] + 19} ${P[1] + 38} C ${P[0] + 19} 100 ${K2[0] + 19} 92 ${K2[0] + 19} ${K2[1]}" stroke="#d9c9f0" stroke-width="1.6"/>
        </svg>`;
        const par = fxEl(`<div class="fxevo" style="left:${P[0]}px;top:${P[1]}px">${face(parentMouth)}</div>`);
        const m1 = EVO_MOUTHS[Math.floor(Math.random() * EVO_MOUTHS.length)];
        const m2 = EVO_MOUTHS[Math.floor(Math.random() * EVO_MOUTHS.length)];
        const k1 = fxEl(`<div class="fxevo" style="left:${K1[0]}px;top:${K1[1]}px">${face(m1)}</div>`);
        const k2 = fxEl(`<div class="fxevo" style="left:${K2[0]}px;top:${K2[1]}px">${face(m2)}</div>`);
        stage.append(par, k1, k2);
        stage.querySelectorAll(".eb").forEach(p => {
          const L = p.getTotalLength();
          p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
          gsap.to(p, { strokeDashoffset: 0, duration: .5, delay: .25, ease: "power2.out" });
        });
        gsap.from([k1, k2], { scale: 0, duration: .45, delay: .6, stagger: .15, ease: "back.out(3)" });
        const win = Math.random() < .5 ? k1 : k2;
        const lose = win === k1 ? k2 : k1;
        const winM = win === k1 ? m1 : m2;
        later(1.7, () => {
          win.classList.add("won");
          gsap.fromTo(win, { scale: 1 }, { scale: 1.12, duration: .25, yoyo: true, repeat: 1 });
          gsap.to(lose, { autoAlpha: .15, duration: .5 });
        });
        later(2.6, () => {
          gsap.to(win, { left: P[0], top: P[1], duration: .6, ease: "power2.inOut" });
          gsap.to([par, stage.querySelector("svg"), lose], { autoAlpha: 0, duration: .4 });
        });
        later(3.6, () => cycle(winM));
      }
      cycle(EVO_MOUTHS[0]);
      return () => { alive = false; pending.forEach(c => c.kill()); };
    } },
  { title: "your word is code", mood: "hopeful",
    sub: "a prompt disappears the moment you send it. your words don't — they compile into real code, through a compiler learning the language of you.",
    fx(fx) {
      // TWO PANES, one story: rules.md ⇄ rules.work. Changes arrive as DIFFS on
      // the english and propagate as DIFFS in the machinery. No cursor, no lanes —
      // just red out, green in, on both sides of the compile.
      const arrow = fxEl(`<div style="position:absolute;inset:0"></div>`);
      arrow.innerHTML = `<svg viewBox="0 0 480 230" width="480" height="230" fill="none"
          stroke="#b9a9d9" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <g id="fxa1"><path class="am" d="M188 40 C 222 26, 254 26, 288 38"/><path class="ah" d="M280 32 l 9 6 -10 5"/></g>
      </svg>`;
      const rowHTML = ([id, text, cls]) =>
        `<div class="fxrow"${id ? ` data-id="${id}"` : ""}><span class="fxg"></span><span class="fxt${cls ? " " + cls : ""}">${text}</span></div>`;
      const MD = [
        ["", "# rules", "cmt"],
        ["", "match invoice emails."],
        ["", "check against budget."],
        ["m-th", "past 80%, ask my sign-off."],
        ["", "keep the tone warm."]
      ];
      const WK = [
        ["", "hook :email do", "kw"],
        ["", "  match kind: :invoice"],
        ["w-run", "  run :check_budget"],
        ["", "end", "kw"],
        ["", "def check_budget do", "kw"],
        ["", "  load = spent() + amount"],
        ["w-th", "  if load > 0.8 * budget,"],
        ["w-act", "    do: notify(:me)"],
        ["", "end", "kw"]
      ];
      const ed = fxEl(`<div class="fxed" style="left:0;top:14%;width:182px">
        <div class="fxedhdr"><span class="dot"></span><span class="dot"></span><span class="dot"></span>
          <img src="/static/micons/markdown.svg" width="11" height="11" alt="">rules.md — yours</div>
        <div class="fxdiffbody">${MD.map(rowHTML).join("")}</div></div>`);
      const work = fxEl(`<div class="fxed" style="right:0;top:5%;width:188px">
        <div class="fxedhdr"><img src="/static/micons/tune.svg" width="11" height="11" alt="" style="margin-left:0">rules.work · derived</div>
        <div class="fxdiffbody">${WK.map(rowHTML).join("")}</div></div>`);
      fx.append(arrow, ed, work);
      fxIn(ed, .15); fxIn(work, .6);
      const p = arrow.querySelector(".am"), L = p.getTotalLength();
      p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
      gsap.to(p, { strokeDashoffset: 0, duration: .7, delay: .8, ease: "power2.inOut" });
      gsap.from(arrow.querySelector(".ah"), { autoAlpha: 0, duration: .3, delay: 1.35 });
      const face = document.getElementById("slideface");
      let alive = true;
      const calls = [];
      const later = (t, f) => calls.push(gsap.delayedCall(t, f));
      const pulse = g => gsap.fromTo(g, { opacity: .35 }, { opacity: 1, duration: .3, yoyo: true, repeat: 1 });
      const row = (host, id) => host.querySelector(`[data-id="${id}"]`);
      // one diff, classic grammar: old row goes red −, new row lands green +,
      // then the diff SETTLES — red collapses away, green becomes plain truth
      const step = (host, op, at) => {
        later(at, () => {
          const r = row(host, op.id);
          if (!r) return;
          if (op.del) { r.classList.add("rowdel"); return; }
          if (op.to || op.add) {
            if (op.to) r.classList.add("rowdel");
            const nr = fxEl(rowHTML([op.id + "+", op.to || op.add]));
            nr.classList.add("rowadd");
            r.after(nr);
            gsap.from(nr, { height: 0, autoAlpha: 0, duration: .35, ease: "power2.out" });
          }
        });
        later(at + 1.9, () => {
          const r = row(host, op.id), nr = row(host, op.id + "+");
          if (op.del || op.to) {
            if (r) gsap.to(r, { height: 0, autoAlpha: 0, duration: .35, onComplete: () => r.remove() });
          }
          if (nr) { nr.classList.remove("rowadd"); nr.dataset.id = op.add ? op.newId : op.id; }
        });
      };
      // the cycle: threshold · action · a whole new rule — in, then back out.
      // every md diff propagates to its work diff ~a beat later.
      const CYCLES = [
        [{ id: "m-th", to: "past 90%, ask my sign-off." }, { id: "w-th", to: "  if load > 0.9 * budget," }],
        [{ id: "m-th", to: "past 90%, loop finance in." }, { id: "w-act", to: "    do: notify(:finance)" }],
        [{ id: "m-th", add: "log every invoice, too.", newId: "m-log" }, { id: "w-run", add: "  run :log_ledger", newId: "w-log" }],
        [{ id: "m-th", to: "past 80%, loop finance in." }, { id: "w-th", to: "  if load > 0.8 * budget," }],
        [{ id: "m-th", to: "past 80%, ask my sign-off." }, { id: "w-act", to: "    do: notify(:me)" }],
        [{ id: "m-log", del: true }, { id: "w-log", del: true }]
      ];
      let k = 0;
      function cycle() {
        if (!alive) return;
        const [mOp, wOp] = CYCLES[k++ % CYCLES.length];
        step(ed, mOp, 0);
        later(.8, () => { pulse(arrow.querySelector("#fxa1")); gsap.fromTo(face, { scale: 1 }, { scale: 1.05, duration: .18, yoyo: true, repeat: 1 }); });
        step(work, wOp, 1.0);
        later(4.6, cycle);
      }
      later(2.4, cycle);
      return () => { alive = false; calls.forEach(c => c.kill()); };
    } },
  { title: "it becomes real", mood: "superHappy",
    sub: "you write prose, not config — it dissects the meaning and each piece becomes living structure.",
    fx(fx) {
      // LEFT: a real paragraph of natural language, parsed before your eyes —
      // each span lights in the color of the node it becomes
      const COL = ["#8e7cc3", "#6aa84f", "#c9a04e"];
      const doc = fxEl(`<div class="fxcard" style="left:1%;top:18%;width:152px;white-space:normal">` +
        `<span class="astp">Build me a quiet landing page.</span> ` +
        `<span class="astp">Every Friday, remind me to ship the changelog.</span> ` +
        `<span class="astp">And keep the tone warm.</span></div>`);
      fx.append(doc);
      fxIn(doc);
      const wires = fxEl(`<div style="position:absolute;inset:0"></div>`);
      wires.innerHTML = `<svg viewBox="0 0 480 230" width="480" height="230" fill="none">
        <path class="fxlink" d="M298 115 C332 115 332 60 366 60" stroke="#8e7cc3" stroke-opacity=".45" stroke-width="1.6"/>
        <path class="fxlink" d="M298 115 C338 115 338 118 374 118" stroke="#6aa84f" stroke-opacity=".45" stroke-width="1.6"/>
        <path class="fxlink" d="M298 115 C332 115 332 172 362 172" stroke="#c9a04e" stroke-opacity=".45" stroke-width="1.6"/>
      </svg>`;
      fx.append(wires);
      // wire endpoints are circle CENTERS — offset the 14px dots by half their size
      const mk = (cy, cx, bg) => fxEl(`<div class="fxnode" style="top:${cy - 7}px;left:${cx - 7}px;background:${bg}"></div>`);
      const nodes = [mk(60, 366, COL[0]), mk(118, 374, COL[1]), mk(172, 362, COL[2])];
      nodes.forEach(n => fx.append(n));
      // parse sweep: sentence k highlights → its wire draws → its node pops
      const spans = doc.querySelectorAll(".astp");
      const links = wires.querySelectorAll(".fxlink");
      spans.forEach((sp, k) => {
        const d = 1.0 + k * .75;
        gsap.to(sp, { backgroundColor: COL[k] + "29", borderBottomColor: COL[k], duration: .4, delay: d });
        const p = links[k], L = p.getTotalLength();
        p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
        gsap.to(p, { strokeDashoffset: 0, duration: .7, delay: d + .25, ease: "power2.out" });
        gsap.from(nodes[k], { scale: 0, duration: .5, delay: d + .55, ease: "back.out(3)" });
      });
      gsap.to(nodes, { y: "-=5", duration: 2, yoyo: true, repeat: -1, ease: "sine.inOut", stagger: .3, delay: 3.6 });
    } },
  { title: "sketches count too", mood: "hopeful",
    sub: "or draw it instead — a rough sketch becomes a working component.",
    fx(fx) {
      // LEFT: the hand-drawn wireframe (strokes draw themselves)…
      const sketch = fxEl(`<div class="fxcard" style="left:2%;top:22%;width:128px;height:92px;padding:8px"></div>`);
      sketch.innerHTML = `<svg viewBox="0 0 112 76" width="112" height="76" fill="none"
          stroke="#8e7cc3" stroke-width="2" stroke-linecap="round">
        <path d="M10 12 Q8 6 16 7 L96 5 Q106 4 105 13 L106 62 Q107 70 98 69 L15 71 Q8 72 9 64 Z"/>
        <circle cx="26" cy="26" r="8"/>
        <path d="M42 20 Q66 18 92 20"/>
        <path d="M42 32 Q60 31 78 32"/>
        <path d="M66 48 Q64 46 70 46 L92 45 Q98 45 97 51 L97 55 Q97 60 91 59 L70 60 Q65 61 66 55 Z"/>
      </svg>`;
      fx.append(sketch);
      fxIn(sketch);
      sketch.querySelectorAll("path, circle").forEach((p, k) => {
        const L = p.getTotalLength();
        p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
        gsap.to(p, { strokeDashoffset: 0, duration: .7, delay: .4 + k * .3, ease: "power2.inOut" });
      });
      // …RIGHT: the same shape, implemented for real — avatar, text, button
      const comp = fxEl(`<div class="fxcomp">
        <div class="fxcompav"></div>
        <div class="fxcomplines"><div class="fxline" style="width:62px"></div><div class="fxline" style="width:44px"></div></div>
        <div class="fxcompbtn">go</div>
      </div>`);
      fx.append(comp);
      gsap.from(comp, { autoAlpha: 0, x: -24, scale: .82, duration: .6, delay: 2.1, ease: "back.out(1.8)" });
      gsap.from(comp.querySelector(".fxcompav"), { scale: 0, duration: .45, delay: 2.4, ease: "back.out(3)" });
      gsap.from(comp.querySelectorAll(".fxline"), { width: 0, duration: .45, delay: 2.5, stagger: .15, ease: "power2.out" });
      gsap.from(comp.querySelector(".fxcompbtn"), { scale: 0, duration: .45, delay: 2.85, ease: "back.out(3)" });
    } },
  { title: "but sure, you can chat", mood: "happy",
    sub: "chat and voice are right there too — real tool calls and all. (yes, after everything you just saw. some days you want to talk.)",
    fx(fx) {
      // LEFT: chat with visible tool calls…
      const chat = fxEl(`<div class="fxchat" style="left:1%;top:12%">
        <div class="fxmsg user">add a pricing page?</div>
        <div class="fxtool"><i data-lucide="wrench"></i>write: pricing.work</div>
        <div class="fxtool"><i data-lucide="git-branch"></i>link: nav → pricing</div>
        <div class="fxmsg bot">done — on the graph</div>
      </div>`);
      // …RIGHT: voice — waveform docked in its own panel, same tool-call shape
      const voice = fxEl(`<div class="fxchat" style="right:1%;top:20%">
        <div class="fxvoice"><span class="vb"></span><span class="vb"></span><span class="vb"></span><span class="vb"></span><span class="vb"></span><span class="vb"></span><span class="vb"></span></div>
        <div class="fxmsg user">“make the hero bolder”</div>
        <div class="fxtool"><i data-lucide="pencil"></i>edit: hero.ts</div>
      </div>`);
      fx.append(chat, voice);
      refreshIcons();
      gsap.from(chat.children, { autoAlpha: 0, y: 8, duration: .4, stagger: .5, delay: .3, ease: "power2.out" });
      gsap.from(voice.children, { autoAlpha: 0, y: 8, duration: .4, stagger: .5, delay: 1.0, ease: "power2.out" });
      gsap.to(voice.querySelectorAll(".vb"), { scaleY: () => 0.5 + Math.random() * 2.4, duration: .28,
        yoyo: true, repeat: -1, repeatRefresh: true, stagger: .07, ease: "sine.inOut", delay: 1.2 });
      // and the face TALKS along — the REAL voice mouth-sync (viseme chart +
      // playhead classifier, 50ms cadence), driven by a scripted line + envelope
      const line = "done. I wrote the pricing page and linked it into the nav for you.";
      const t0 = performance.now(), dur = 4600;
      let lastV = null;
      const talk = setInterval(() => {
        const m = _slideFaceApi && _slideFaceApi.el("mouth");
        if (!m) return;
        const frac = ((performance.now() - t0) % dur) / dur;
        // synthetic speech envelope: syllable pulses + a rest at the loop seam
        const amp = frac > .9 ? 0 : .3 + .5 * Math.abs(Math.sin(frac * Math.PI * 16)) * (.6 + Math.random() * .4);
        const v = visemeAt(line, frac, amp);
        if (v === lastV) return;
        lastV = v;
        if (v === "X") _slideFaceApi.setMouth("happy");
        else m.innerHTML = VISEMES[v];
      }, 50);
      return () => clearInterval(talk);
    } },
  { title: "it files its own work", mood: "hopeful",
    sub: "each heartbeat scans the body for drift — gaps become issues it files for itself, then claims and closes on a later beat.",
    fx(fx) {
      // LEFT — what happened: the scan found drift
      const scan = fxEl(`<div class="fxchat" style="left:1%;top:20%;width:148px">
        <div class="fxtool"><i data-lucide="heart-pulse"></i>heartbeat № 214</div>
        <div class="fxmsg bot">stale page: oota.md</div>
        <div class="fxmsg bot">hook without a match</div>
      </div>`);
      // RIGHT — how it reacted: issues filed, then one claimed + closed
      const q = fxEl(`<div class="fxchat" style="right:1%;top:18%;width:152px">
        <div class="fxtool"><i data-lucide="git-pull-request"></i>issue queue</div>
        <div class="fxmsg bot" id="fxi1">#12 refresh oota.md</div>
        <div class="fxmsg bot" id="fxi2">#13 rewire the hook</div>
      </div>`);
      fx.append(scan, q);
      refreshIcons();
      gsap.from(scan.children, { autoAlpha: 0, y: 8, duration: .4, stagger: .45, delay: .3, ease: "power2.out" });
      gsap.from(q.children, { autoAlpha: 0, y: 8, duration: .4, stagger: .45, delay: 1.2, ease: "power2.out" });
      // beat № 215: it claims #12 and closes it
      const done = gsap.delayedCall(3.1, () => {
        const r = q.querySelector("#fxi1");
        if (!r) return;
        r.style.borderColor = "#bcd9ac"; r.style.background = "#f2f8ee"; r.style.color = "#4d7a3a";
        r.textContent = "✓ " + r.textContent;
        gsap.fromTo(r, { scale: 1 }, { scale: 1.06, duration: .2, yoyo: true, repeat: 1 });
      });
      return () => done.kill();
    } },
  { title: "this is your world", mood: "neutral",
    sub: "the graph is the whole interface. every node is a real running thing — pages, rules, agents — grouped into living clusters with membranes. not a picture of your notes; the notes, alive.",
    fx(fx) {
      // the real interface in miniature: live physics, a breathing cluster
      // membrane with its badge, everything orbiting the machine — not a mural
      const holder = fxEl(`<div style="position:absolute;inset:0"></div>`);
      holder.innerHTML = `<svg viewBox="0 0 480 230" width="480" height="230" fill="none"></svg>`;
      fx.append(holder);
      const svg = d3.select(holder.querySelector("svg"));
      const hullLayer = svg.append("g");
      const linkLayer = svg.append("g");
      const nodeLayer = svg.append("g");
      const badgeLayer = svg.append("g");
      const nodes = [
        { id: "self", fx: 240, fy: 115, x: 240, y: 115 },
        { id: "launch page", c: "#8e7cc3", cl: 1, x: 350, y: 120 },
        { id: "pricing", c: "#8e7cc3", cl: 1, x: 390, y: 150 },
        { id: "hero copy", c: "#8e7cc3", cl: 1, x: 360, y: 180 },
        { id: "changelog", c: "#8e7cc3", cl: 1, x: 410, y: 110 },
        { id: "rules.work", c: "#c9a04e", lab: 1, x: 110, y: 60 },
        { id: "sketch", c: "#6aa84f", x: 80, y: 130 },
        { id: "research", c: "#d96ba0", lab: 1, x: 130, y: 190 },
        { id: "ledger", c: "#2aa198", x: 60, y: 90 },
        { id: "deck agent", c: "#4a90d9", x: 150, y: 30 }
      ];
      const links = nodes.slice(1).map(n => ({ source: "self", target: n.id }));
      const CL = [368, 148];
      const sim = d3.forceSimulation(nodes)
        .force("link", d3.forceLink(links).id(d => d.id).distance(d => d.target.cl ? 125 : 92).strength(.15))
        .force("charge", d3.forceManyBody().strength(-55).distanceMax(150))
        .force("collide", d3.forceCollide(d => d.id === "self" ? 64 : 15))
        .force("cluster", a => {
          for (const n of nodes) {
            if (n.cl) { n.vx += (CL[0] - n.x) * a * .16; n.vy += (CL[1] - n.y) * a * .16; }
            if (n.id !== "self") { n.vx += (Math.random() - .5) * .18; n.vy += (Math.random() - .5) * .18; }
          }
        })
        .alpha(.09).alphaDecay(0).velocityDecay(.5);
      const line = linkLayer.selectAll("line").data(links).join("line")
        .attr("stroke", "var(--edge)").attr("stroke-width", 1);
      const dot = nodeLayer.selectAll("circle").data(nodes.slice(1)).join("circle")
        .attr("r", 7).attr("fill", d => d.c);
      const lab = nodeLayer.selectAll("text").data(nodes.slice(1).filter(d => d.lab)).join("text")
        .attr("font-size", 7.5).attr("font-family", "ui-monospace,monospace").attr("fill", "var(--ink-faint)")
        .attr("text-anchor", "middle").text(d => d.id);
      const hull = hullLayer.append("path")
        .attr("fill", "var(--purple)").attr("fill-opacity", .07)
        .attr("stroke", "var(--purple)").attr("stroke-opacity", .35)
        .attr("stroke-width", 1.4).attr("stroke-linejoin", "round");
      const pill = badgeLayer.append("g");
      pill.append("rect").attr("width", 52) .attr("height", 15).attr("rx", 7.5).attr("fill", "var(--purple)");
      pill.append("text").attr("x", 26).attr("y", 10.5).attr("text-anchor", "middle")
        .attr("font-size", 8).attr("font-family", "ui-monospace,monospace")
        .attr("font-weight", 600).attr("fill", "#fff").text("# launch");
      sim.on("tick", () => {
        line.attr("x1", d => d.source.x).attr("y1", d => d.source.y)
            .attr("x2", d => d.target.x).attr("y2", d => d.target.y);
        dot.attr("cx", d => d.x).attr("cy", d => d.y);
        lab.attr("x", d => d.x).attr("y", d => d.y + 17);
        const pts = nodes.filter(n => n.cl).map(n => [n.x, n.y]);
        const [cx, cy] = [d3.mean(pts, p => p[0]), d3.mean(pts, p => p[1])];
        const off = (d3.polygonHull(pts) || pts).map(([x, y]) => {
          const dx = x - cx, dy = y - cy, L = Math.hypot(dx, dy) || 1;
          return [x + dx / L * 22, y + dy / L * 22];
        });
        // rounded membrane corners, like the real thing
        const n = off.length;
        let d = "";
        for (let i = 0; i < n; i++) {
          const p0 = off[(i + n - 1) % n], p1 = off[i], p2 = off[(i + 1) % n];
          const l1 = Math.hypot(p1[0] - p0[0], p1[1] - p0[1]) || 1, l2 = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) || 1;
          const r = Math.min(14, l1 / 2, l2 / 2);
          const a = [p1[0] - (p1[0] - p0[0]) / l1 * r, p1[1] - (p1[1] - p0[1]) / l1 * r];
          const b = [p1[0] + (p2[0] - p1[0]) / l2 * r, p1[1] + (p2[1] - p1[1]) / l2 * r];
          d += (i ? "L" : "M") + a.map(v => v.toFixed(1)) + " Q" + p1.map(v => v.toFixed(1)) + " " + b.map(v => v.toFixed(1)) + " ";
        }
        hull.attr("d", d + "Z");
        const top = off.reduce((a, p) => p[1] < a[1] ? p : a, off[0]);
        pill.attr("transform", `translate(${top[0] - 26},${top[1] - 22})`);
      });
      gsap.from(holder, { autoAlpha: 0, duration: .8, delay: .2 });
      return () => sim.stop();
    } },
  { title: "nothing is lost", mood: "neutral",
    sub: "every body write lands in a real jj repo — the console shows the whole braid, and any point rolls back.",
    fx(fx) {
      // LEFT — what happened: an edit (the newest version)
      const card = fxEl(`<div class="fxcard" style="left:1%;top:24%;width:140px;white-space:normal">the hero <b id="fxver">shouts boldly</b>.</div>`);
      const chip = fxEl(`<div class="fxchip" style="left:4%;top:60%">body.wrote → snapshot</div>`);
      // RIGHT — how it's kept: the history console, branches and merges (the braid)
      const dag = fxEl(`<div class="fxcard" style="right:2%;top:12%;width:120px;padding:8px 10px">` +
        `<div class="fxfile" style="margin-bottom:4px;color:#8e7cc3"><i data-lucide="history"></i>history</div>` +
        `<div style="position:relative"><svg viewBox="0 0 96 108" width="96" height="108" fill="none">
          <path id="dagmain" d="M20 100 L20 8" stroke="#d9c9f0" stroke-width="2"/>
          <path id="dagbranch" d="M20 78 C42 78 42 70 42 58 L42 40 C42 28 42 24 20 22" stroke="#e6d3a8" stroke-width="2"/>
          <circle class="dagc" cx="20" cy="100" r="5" fill="#8e7cc3"/>
          <circle class="dagc" cx="20" cy="78" r="5" fill="#8e7cc3"/>
          <circle class="dagc" cx="42" cy="58" r="5" fill="#c9a04e"/>
          <circle class="dagc" cx="42" cy="40" r="5" fill="#c9a04e"/>
          <circle class="dagc" cx="20" cy="52" r="5" fill="#8e7cc3"/>
          <circle class="dagc" cx="20" cy="22" r="6" fill="#8e7cc3"/>
          <circle id="dagring" cx="20" cy="22" r="9" stroke="#1c2230" stroke-width="1.6"/>
        </svg></div></div>`);
      fx.append(card, chip, dag);
      refreshIcons();
      fxIn(card, .15); fxIn(chip, .4); fxIn(dag, .3);
      // the braid grows: main rail, then the branch, dots in commit order
      for (const id of ["dagmain", "dagbranch"]) {
        const p = dag.querySelector("#" + id), L = p.getTotalLength();
        p.style.strokeDasharray = L; p.style.strokeDashoffset = L;
        gsap.to(p, { strokeDashoffset: 0, duration: id === "dagmain" ? .9 : 1.1, delay: id === "dagmain" ? .6 : 1.0, ease: "power2.inOut" });
      }
      gsap.from(dag.querySelectorAll(".dagc"), { scale: 0, transformOrigin: "center", duration: .35, delay: .8, stagger: .28, ease: "back.out(3)" });
      // scrub: the ring walks back to an older commit — the text follows (undo), then returns
      const ring = dag.querySelector("#dagring");
      const ver = card.querySelector("#fxver");
      const tl = gsap.timeline({ repeat: -1, repeatDelay: 1.6, delay: 3.2 });
      tl.to(ring, { attr: { cy: 78 }, duration: .6, ease: "power2.inOut" })
        .call(() => { ver.textContent = "speaks quietly"; })
        .to({}, { duration: 1.3 })
        .to(ring, { attr: { cy: 22 }, duration: .6, ease: "power2.inOut" })
        .call(() => { ver.textContent = "shouts boldly"; });
      return () => tl.kill();
    } },
  { title: "nothing escapes", mood: "neutral",
    sub: "everything it runs, it runs in sealed little worlds — born, executed, gone in a blink. each one convincingly real to the code inside. yours never feels a thing.",
    fx(fx) {
      // a swarm of tiny sandboxes: sealed boxes blink into being around the machine,
      // run their thing (shell, python, rust, sql…), flash done, and vanish
      const ICONS = ["console", "python", "rust", "javascript", "typescript", "go", "ruby",
        "zig", "c", "cpp", "database", "powershell", "webassembly", "elixir", "svelte", "html"];
      const SLOTS = [
        [20, 22], [84, 10], [134, 50], [28, 78], [96, 106], [22, 146], [118, 164], [66, 192],
        [352, 16], [420, 38], [336, 70], [398, 100], [446, 130], [342, 148], [406, 176], [452, 66]
      ];
      const busy = new Array(SLOTS.length).fill(false);
      let alive = true;
      const calls = [];
      const later = (t, f) => calls.push(gsap.delayedCall(t, f));
      function spawn() {
        if (!alive) return;
        const free = SLOTS.map((_, i) => i).filter(i => !busy[i]);
        if (free.length) {
          const i = free[Math.floor(Math.random() * free.length)];
          busy[i] = true;
          const icon = ICONS[Math.floor(Math.random() * ICONS.length)];
          const b = fxEl(`<div class="fxsbx" style="left:${SLOTS[i][0]}px;top:${SLOTS[i][1]}px">` +
            `<img src="/static/micons/${icon}.svg" width="14" height="14" alt=""></div>`);
          fx.append(b);
          gsap.from(b, { scale: 0, duration: .4, ease: "back.out(2.5)" });
          later(1.3 + Math.random() * 1.7, () => {
            if (!alive) return;
            b.classList.add("done");   // executed clean — a green blink, then gone
            gsap.to(b, { scale: 0, autoAlpha: 0, duration: .35, delay: .3, ease: "back.in(2)",
              onComplete: () => { b.remove(); busy[i] = false; } });
          });
        }
        later(.38 + Math.random() * .34, spawn);
      }
      spawn();
      return () => { alive = false; calls.forEach(c => c.kill()); };
    } },
  { title: "polyglot by default", mood: "happy",
    sub: "raising a polymath takes a lifetime. this ships as a polyglot — every language compiled to its own little island, server-side or client-side.",
    fx(fx) {
      // an archipelago: server islands port-side, client islands starboard
      const isle = (icon, name, tag) => fxEl(
        `<div class="fxisle"><img src="/static/micons/${icon}.svg" width="16" height="16" alt="">` +
        `<span class="finame">${name}</span><span class="fitag">${tag}</span></div>`);
      const server = [["rust", "rust"], ["python", "python"], ["elixir", "elixir"]]
        .map(([i, n]) => isle(i, n, "server island"));
      const client = [["svelte", "svelte"], ["typescript", "typescript"], ["javascript", "javascript"]]
        .map(([i, n]) => isle(i, n, "client island"));
      const spots = [[4, 12], [16, 44], [6, 74]];
      server.forEach((el, k) => { el.style.left = spots[k][0] + "%"; el.style.top = spots[k][1] + "%"; fx.append(el); });
      client.forEach((el, k) => { el.style.right = spots[k][0] + "%"; el.style.top = spots[k][1] + "%"; fx.append(el); });
      const all = [...server, ...client];
      gsap.from(all, { scale: 0, autoAlpha: 0, duration: .5, delay: .3, stagger: .14, ease: "back.out(2.2)" });
      // islands bob — it's an archipelago, after all
      gsap.to(all, { y: "-=6", duration: 2.4, yoyo: true, repeat: -1, ease: "sine.inOut", stagger: .35, delay: 1.4 });
    } },
  { title: "dense by design", mood: "superHappy",
    sub: "one engine carries everything — sites, agents, sealed worlds. forget zero to one: you build zero to a hundred without thinking about it.",
    fx(fx) {
      // LEFT: the engine and its three duties, one panel. RIGHT: the bloom — 1 → n.
      const eng = fxEl(`<div class="fxchat" style="left:0;top:22%;width:152px">
        <div class="fxtool" style="border-style:solid;justify-content:center"><i data-lucide="cpu"></i>one engine</div>
        <div class="fxmsg bot" style="align-self:stretch">hosts your sites</div>
        <div class="fxmsg bot" style="align-self:stretch">runs your agents</div>
        <div class="fxmsg bot" style="align-self:stretch">seals the worlds</div>
      </div>`);
      // RIGHT: your app — then the SAME app, cloned live for everyone
      const mini = (you) => fxEl(
        `<div class="fxmini${you ? " you" : ""}"><span class="mbar"></span><span class="mln"></span><span class="mln s"></span><span class="mdot"></span></div>`);
      const grid = fxEl(`<div class="fxgrid" style="right:1%;top:18%"></div>`);
      const minis = Array.from({ length: 9 }, (_, i) => mini(i === 0));
      minis.forEach(m => grid.append(m));
      const glab = fxEl(`<div class="fxlab" style="right:3%;top:74%">your build, serving everyone.</div>`);
      fx.append(eng, grid, glab);
      refreshIcons();
      fxIn(eng, .2);
      gsap.from(eng.querySelectorAll(".fxmsg"), { autoAlpha: 0, x: -12, duration: .4, delay: .6, stagger: .22, ease: "power2.out" });
      // one app appears… then the engine deals out identical copies, each going live
      gsap.set(minis.slice(1), { autoAlpha: 0 });
      gsap.from(minis[0], { scale: 0, duration: .5, delay: 1.4, ease: "back.out(2.5)" });
      gsap.to(minis.slice(1), { autoAlpha: 1, duration: .3, delay: 2.1, stagger: .14, ease: "power1.out" });
      gsap.from(minis.slice(1), { scale: .4, duration: .3, delay: 2.1, stagger: .14, ease: "back.out(2)" });
      gsap.from(glab, { autoAlpha: 0, duration: .5, delay: 3.6 });
    } },
  { title: "run it in the cloud", mood: "superHappy",
    sub: "on your machine the autopoet works while you watch. on Workbooks Cloud it works while you sleep — 24/7, with a real toolbelt, phone, and inbox of its own.",
    fx(fx) {
      const panel = fxEl(`<div class="fxchat" style="left:50%;top:16%;transform:translateX(-50%);width:230px;align-items:stretch">
        <div class="fxtool" style="border-style:solid;justify-content:center"><i data-lucide="cloud"></i>Workbooks Cloud</div>
        <div class="fxmsg bot"><i data-lucide="infinity" style="width:13px;height:13px;vertical-align:-2px"></i> always on — 24/7, no lid to close</div>
        <div class="fxmsg bot"><i data-lucide="blocks" style="width:13px;height:13px;vertical-align:-2px"></i> hundreds of tools, via Composio</div>
        <div class="fxmsg bot"><i data-lucide="phone" style="width:13px;height:13px;vertical-align:-2px"></i> its own phone number</div>
        <div class="fxmsg bot"><i data-lucide="mail" style="width:13px;height:13px;vertical-align:-2px"></i> its own inbox — email built in</div>
      </div>`);
      const lab = fxEl(`<div class="fxlab" style="left:50%;bottom:8%;transform:translateX(-50%)">connect it any time from the app.</div>`);
      fx.append(panel, lab);
      refreshIcons();
      fxIn(panel, .2);
      gsap.from(panel.querySelectorAll(".fxmsg"), { autoAlpha: 0, x: -12, duration: .4, delay: .5, stagger: .2, ease: "power2.out" });
      gsap.from(lab, { autoAlpha: 0, duration: .5, delay: 1.6 });
    } }
];
let _slideFaceApi = null, _slideIdx = -1, _slideCleanup = null, _slidesKeyed = false;
function obDone() { authedPost("/auth/onboarding/done").then(() => location.reload()); }

// POWER GATE — after the deck, before the quiz: how does the agent get its AI?
// Workbooks Cloud (paid machine, AI via the gateway) OR bring-your-own OpenRouter
// (local, free). One is required to continue — this is what was missing.
function loadScript(src) {
  return new Promise((res, rej) => {
    if (document.querySelector(`script[src="${src}"]`)) return res();
    const s = document.createElement("script");
    s.src = src; s.onload = res; s.onerror = rej;
    document.head.appendChild(s);
  });
}
async function showPlanMode(previewPairing) {
  if (_slideCleanup) { _slideCleanup(); _slideCleanup = null; }
  document.getElementById("onboard").classList.remove("hidden");
  document.getElementById("obslides").style.display = "none";
  document.getElementById("obsteps").style.display = "none";
  document.getElementById("obquiz").style.display = "none";
  document.querySelector("#onboard .obinner").style.display = "none";
  try {
    // ONBOARDING is its OWN stage — a standalone whiteboard (own grid, own
    // cube), fully SEPARATE from the dashboard vault graph. No adopt hooks:
    // the requisition form lands on this grid, then the character enters and
    // performs its intro. (The live in-dashboard voice call still adopts the
    // real self node — that path is untouched.)
    await loadScript("/static/planmode.js");
    hideOnboard();                    // the overlay yields to the whiteboard
    const ok = PlanMode.start({
      pairing: previewPairing || null,   // lab preview skips the form
      stage: { token: TOKEN, stage: document.getElementById("stage"), settleMs: 620 },
      refreshIcons,
      onDone: obDone
    });
    if (!ok) showQuiz();              // a live call owns the stage — fall back
  } catch (e) {
    // stage failed to load → the quiz still gets you onboarded (silent fallback)
    document.getElementById("onboard").classList.remove("hidden");
    showQuiz();
  }
}

// INLINE Workbooks Cloud billing — machine + initial tokens + auto-top-up, one
// card. Reuses the cloud's billing endpoints through the desktop's PAT; the Polar
// checkout opens in an in-app modal (with an open-in-browser fallback), and we
// poll the subscription until it's active. The SAME flow the dashboard exposes.
function showQuiz() { showPower(); }
function showSlides() {
  // The GSAP deck is retired: the character's own intro in plan mode IS the
  // introduction now (form AP-7 → pairing → the cube enters and performs).
  // Straight to the compute/inference gates, which lead into plan mode.
  // (showSlidesDeck stays below for dev spelunking.)
  showPower();
}
function showSlidesDeck() {
  // pre-warm the DEFAULT voice's engine while the deck plays — the first plan
  // line meets a READY engine speaking the RIGHT voice
  fetch("/voices/default.json").then(r => r.json()).then(d => {
    const model = d && d.engine === "qwen-clone" ? "base" : d && d.engine === "qwen-design" ? "design" : "custom";
    return fetch("/voice/tts/qwen/boot?model=" + model, { method: "POST",
      headers: { authorization: "Bearer " + TOKEN } });
  }).catch(() => {});
  // deck start → refresh the power prefetch so step 1 paints with live data
  if (typeof firePowerPrefetch === "function") firePowerPrefetch();
  document.querySelector("#onboard .obinner").style.display = "none";
  document.getElementById("obsteps").style.display = "none";
  const deck = document.getElementById("obslides");
  deck.style.display = "flex";
  if (!_slideFaceApi)
    createFace(document.getElementById("slideface"), { idPrefix: "sl" }).then(api => {
      _slideFaceApi = api; api.setMouth(SLIDES[Math.max(0, _slideIdx)].mood);
    });
  document.getElementById("sldots").innerHTML = SLIDES.map(() => `<div class="sldot"></div>`).join("");
  document.getElementById("slprev").onclick = () => slideGo(_slideIdx - 1);
  document.getElementById("slnext").onclick = () => slideGo(_slideIdx + 1);
  document.getElementById("obskip").onclick = showPower;
  document.getElementById("slenter").onclick = showPower;
  if (!_slidesKeyed) {
    _slidesKeyed = true;
    addEventListener("keydown", e => {
      if (deck.style.display !== "flex") return;
      if (e.key === "ArrowRight") slideGo(_slideIdx + 1);
      if (e.key === "ArrowLeft") slideGo(_slideIdx - 1);
    });
  }
  _slideIdx = -1;
  slideGo(0, true);
  refreshIcons();
}
function slideGo(i, instant) {
  if (i < 0 || i >= SLIDES.length || i === _slideIdx) return;
  const dir = i > _slideIdx ? 1 : -1;
  _slideIdx = i;
  const s = SLIDES[i];
  const fx = document.getElementById("slidefx");
  const text = document.querySelector("#obslides .slidetext");
  const face = document.getElementById("slideface");
  if (_slideCleanup) { _slideCleanup(); _slideCleanup = null; }
  [...document.getElementById("sldots").children].forEach((d, k) => d.classList.toggle("on", k === i));
  document.getElementById("slprev").style.visibility = i === 0 ? "hidden" : "visible";
  document.getElementById("slnext").style.visibility = i === SLIDES.length - 1 ? "hidden" : "visible";
  document.getElementById("slenter").style.display = i === SLIDES.length - 1 ? "block" : "none";
  const build = () => {
    gsap.killTweensOf(fx.querySelectorAll("*"));
    fx.innerHTML = "";
    document.getElementById("slidetitle").textContent = s.title;
    document.getElementById("slidesub").textContent = s.sub;
    if (_slideFaceApi) _slideFaceApi.setMouth(s.mood);
    _slideCleanup = s.fx(fx) || null;
    // the deck itself tweens INTO the new state (fx + text ride in together)…
    gsap.fromTo([fx, text], { x: 30 * dir, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: .45, ease: "power2.out" });
    // …and the face card takes a little state bump between slides
    gsap.fromTo(face, { scale: .92, rotation: 3 * dir }, { scale: 1, rotation: 0, duration: .6, ease: "back.out(2)" });
  };
  if (instant) return build();
  gsap.to([fx, text], { x: -30 * dir, autoAlpha: 0, duration: .25, ease: "power1.in", onComplete: build });
}
let currentUser = null;
async function initAuth() {
  let st;
  try { st = await (await fetch("/auth/state.json")).json(); }
  catch (_) { return hideOnboard(); }   // no auth backend ⇒ don't block the app
  currentUser = st.user;
  setFooterUser();
  if (st.authenticated && st.onboarded) {
    hideOnboard();
    // proposal-first entry: if the intake agent left its first proposal, open ON it
    IntakeProposal.check({ post: authedPost });
    return;
  }
  if (st.authenticated) return showOnboardSteps();
  showSignIn();
}
function setFooterUser() {
  const el = document.querySelector("#foot-profile .uinitial");
  if (el) el.textContent = ((currentUser && currentUser.name) || "·").slice(0, 1).toLowerCase();
}
// THE MAIN DOOR — Sign in with Workbooks. Opens the deployed cloud login via the
// device flow (?device=&cb=<localhost>); the cloud mints a PAT and redirects to
// our callback, which stores it AND establishes the local session. The callback
// tab postMessages us on success → we re-check auth state and flow into onboarding.
let _cloudPoll = null;
function signInWithWorkbooks() {
  const btn = document.getElementById("ob-workbooks");
  if (btn) { btn.disabled = true; btn.classList.add("waiting"); btn.querySelector && (btn.lastChild.textContent = " opening login…"); }
  authedPost("/auth/cloud/open").catch(() => {});
  // the login opens in the default browser and its callback (localhost) is served
  // by THIS app but in a different process — so postMessage can't reach us. Poll
  // the local session until the callback establishes it, then advance.
  if (_cloudPoll) clearInterval(_cloudPoll);
  _cloudPoll = setInterval(async () => {
    try {
      const st = await (await fetch("/auth/state.json")).json();
      if (st.authenticated) {
        clearInterval(_cloudPoll); _cloudPoll = null;
        // sign-in success → warm the power screen (status + tiers) right now
        if (typeof firePowerPrefetch === "function") firePowerPrefetch();
        initAuth();
      }
    } catch (_) {}
  }, 2000);
}
// same-process fallback (if ever opened as a child window)
window.addEventListener("message", e => {
  if (e.data && e.data.apCloud) {
    if (_cloudPoll) clearInterval(_cloudPoll);
    if (typeof firePowerPrefetch === "function") firePowerPrefetch();
    initAuth();
  }
});
document.getElementById("ob-workbooks").onclick = signInWithWorkbooks;
initAuth();

