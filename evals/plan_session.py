#!/usr/bin/env python3
"""ONBOARDING SESSION EVAL — drive a full simulated plan session against the
RUNNING app and grade it.

What it does (the exact client choreography, headless):
  1. POST /onboard/requisition with a persona form  → the pairing
  2. loop POST /plan/turn as a scripted owner       → the conversation
     - mimics the client: every move.md → POST /voice/deck/add
     - fork → picks option B
  3. structural checks (fork-once, move validity, md sanity, deck growth,
     completion, say lengths) + latency stats (per-turn wall, p50/p95)
  4. POST /plan/judge → LLM rubric (character/questions/coverage/emergence)

Run:  python3 evals/plan_session.py            (app must be up on :4477)
      python3 evals/plan_session.py --fast     (skip the judge)
Exit: 0 pass, 1 structural failure, 2 quality below bar.
"""
import json, re, sys, time, urllib.request

BASE = "http://127.0.0.1:4477"
HOME = __file__.rsplit("/", 2)[0]
TOKEN = open(f"{HOME}/data/ctl").read().split()[1]

# personas exercise different temperaments/domains — pick with --persona=<key>
PERSONAS = {
    "ceramics": {
        "form": {
            "name": "Mara Ellison", "areas": ["running a business", "writing & research"],
            "manner": "gentle", "energy": "calm", "humor": "dry", "verbosity": "balanced",
            "voice_pref": "warm", "accent_pref": "no preference",
            "remarks": "i run a small ceramics studio; computers are not my thing",
        },
        "answers": [
            "i make ceramics and sell at weekend markets. good with my hands, hopeless at computers.",
            "i want people to find my work online and order pieces without me doing tech stuff.",
            "instagram matters most — that's where my buyers are. and a simple order form.",
            "i photograph every piece on my phone already, usually in batches.",
            "i fire the kiln on fridays, so new work lands weekly.",
            "keep it simple. i'd rather have one thing working than five half-done.",
            "yes, exactly that.", "sounds right — you decide the details.",
            "that covers it, honestly.", "no, i think you have everything.",
        ],
    },
    "founder": {
        "form": {
            "name": "Dev Okonkwo", "areas": ["building software", "running a business"],
            "manner": "blunt", "energy": "spirited", "humor": "mandatory", "verbosity": "terse",
            "voice_pref": "deep", "accent_pref": "no preference",
            "remarks": "technical founder, shipping a dev-tools startup, hate fluff",
        },
        "answers": [
            "i'm a solo technical founder. rust and typescript. shipping a CLI for infra teams.",
            "i want a growth engine — docs, changelog, a waitlist that converts. all automated.",
            "github stars and hacker news are my channels. and a launch email list.",
            "i push releases daily, tag them in git.",
            "docs live in markdown in the repo already.",
            "just make it fast and make it mine. no corporate voice.",
            "yeah, tie it to the git tags.", "you pick the stack, i trust you.",
            "good, that's the shape of it.", "nope, ship it.",
        ],
    },
    "teacher": {
        "form": {
            "name": "Priya Raman", "areas": ["learning things", "personal operations"],
            "manner": "direct", "energy": "steady", "humor": "minimal", "verbosity": "storyteller",
            "voice_pref": "bright", "accent_pref": "no preference",
            "remarks": "high-school science teacher, want to organize my lessons and reach students",
        },
        "answers": [
            "i teach high-school physics. i want my lessons and labs organized and shareable.",
            "i'd love students to access materials and quizzes without me emailing PDFs constantly.",
            "google classroom is what the school uses. and i make slides in keynote.",
            "i write everything in google docs first.",
            "new unit every two weeks, roughly.",
            "i want it clear and reliable — students get confused easily.",
            "yes, sync with classroom.", "you decide the layout, you know best.",
            "that's really helpful, thank you.", "no, that's everything.",
        ],
    },
}
_pk = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--persona=")), "ceramics")
FORM = PERSONAS[_pk]["form"]
ANSWERS = PERSONAS[_pk]["answers"]
print(f"══ persona: {_pk} ══")
MAX_TURNS = 30   # eval-harness safety stop, not a product limit


def post(path, payload, timeout=90):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode(),
        headers={"authorization": "Bearer " + TOKEN, "content-type": "application/json"},
        method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read()), time.time() - t0
    except Exception as e:
        return {"error": str(e)}, time.time() - t0


def post_text(path, text):
    req = urllib.request.Request(
        BASE + path, data=text.encode(),
        headers={"authorization": "Bearer " + TOKEN, "content-type": "text/plain"},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


fails, warns = [], []
def check(ok, label):
    print(("  ✓ " if ok else "  ✗ ") + label)
    if not ok: fails.append(label)
def warn(cond, label):
    if cond: warns.append(label); print("  ⚠ " + label)


print("═ 1. REQUISITION")
pairing, dt = post("/onboard/requisition", FORM, timeout=120)
check("name" in pairing and pairing.get("voice"), f"pairing returned ({dt:.1f}s)")
if fails: print(json.dumps(pairing, indent=2)); sys.exit(1)
print(f"  character: {pairing['name']} · voice {pairing['voice']} ({pairing['engine']}) · shape {pairing.get('shape')}")
print(f"  greeting: {pairing['greeting']!r}")
check(len(pairing.get("slides", [])) == 1, "exactly one cover slide")
check(bool(re.match(r"^#\s", pairing["slides"][0]["md"])) if pairing.get("slides") else False, "cover md starts with a title")

print("═ 2. THE SESSION")
post_text("/voice/deck/new", ""); time.sleep(0.5)
deck_adds = 0
if pairing.get("slides"):
    post_text("/voice/deck/add", pairing["slides"][0]["md"]); deck_adds += 1

state = {"form": FORM, "pairing": pairing, "history": [], "fork_done": False, "deck_titles": []}
turn_times, moves_seen, forks, asks, asks_with_md = [], [], 0, 0, 0
answer_i, completed = 0, False
prev_say = [""]

for turn in range(MAX_TURNS):
    # the real client retries hiccups (bad JSON from the fast lane etc.) —
    # the eval extends the same grace: up to 3 attempts per turn
    for attempt in range(3):
        move, dt = post("/plan/turn", {
            "form": state["form"], "pairing": pairing,
            "history": state["history"][-20:], "fork_done": state["fork_done"],
            "deck_titles": state["deck_titles"][-12:]})
        if move.get("move"): break
        warn(True, f"turn {turn}: retry {attempt + 1} ({move.get('error', '?')})")
        time.sleep(1.2)
    turn_times.append(dt)
    m = move.get("move")
    if m is None:
        check(False, f"turn {turn}: bad move after retries: {move}"); break
    moves_seen.append(m)
    say = move.get("say", "")
    print(f"  [{turn:02d}] {dt:4.1f}s {m:<9} {'📄' if move.get('md') else '  '} {say[:76]!r}")
    warn(len(say.split()) > 40, f"turn {turn}: say ran long ({len(say.split())} words)")
    # COHERENCE (owner: 'it repeats itself / gets misaligned before the question')
    nsay = say.strip().lower()[:45]
    check(nsay != prev_say[0], f"turn {turn}: say is not a repeat of the previous line")
    prev_say[0] = nsay
    check(not (m == "slide" and "?" in say), f"turn {turn}: slide say is a statement (no question)")

    if move.get("md"):
        post_text("/voice/deck/add", move["md"]); deck_adds += 1
        state["deck_titles"].append(move.get("title", ""))
    state["history"].append({"role": "assistant", "content": say})

    if m == "ask":
        asks += 1
        if move.get("md"): asks_with_md += 1
        ans = ANSWERS[answer_i] if answer_i < len(ANSWERS) else "you decide — that works for me."
        answer_i += 1
        state["history"].append({"role": "user", "content": ans})
        # a human reads + types between turns; --stress skips the pause to hammer
        # rate limits on purpose
        if "--stress" not in sys.argv: time.sleep(1.5)
    elif m == "fork":
        forks += 1
        opts = move.get("options", [])
        check(len(opts) >= 2, f"fork has {len(opts)} options")
        pick = opts[min(1, len(opts) - 1)]
        print(f"       fork picks: {pick['title']!r}  (of {[o['title'] for o in opts]})")
        if pick.get("md"): post_text("/voice/deck/add", pick["md"]); deck_adds += 1
        state["history"].append({"role": "user", "content": "let's go with: " + pick["title"]})
        state["fork_done"] = True
    elif m == "complete":
        completed = True
        break

print("═ 3. STRUCTURE")
check(completed, f"session completed (in {len(moves_seen)} moves)")
check(forks == 1, f"exactly one fork (saw {forks})")
check(all(m in ("ask", "slide", "fork", "complete") for m in moves_seen), "all moves valid")
req = urllib.request.Request(BASE + "/voice/deck", headers={"authorization": "Bearer " + TOKEN})
deck_md = urllib.request.urlopen(req, timeout=15).read().decode()
slide_count = len(deck_md.split("\n---\n")) if deck_md.strip() else 0
check(slide_count >= max(3, deck_adds - 1), f"deck holds {slide_count} slides ({deck_adds} adds)")
fence_ok = deck_md.count("```") % 2 == 0
check(fence_ok, "mermaid/code fences balanced")
post_fork_asks = asks  # includes pre-fork asks; md-carry matters post-fork mostly
warn(asks and asks_with_md / max(asks, 1) < 0.4, f"only {asks_with_md}/{asks} asks carried a slide (want drafting-while-asking)")

ts = sorted(turn_times)
p50 = ts[len(ts) // 2]; p95 = ts[int(len(ts) * 0.95) - 1] if len(ts) > 1 else ts[0]
print(f"═ 4. LATENCY  turns={len(ts)} p50={p50:.1f}s p95={p95:.1f}s max={max(ts):.1f}s")
check(p50 < 2.5, f"turn p50 under 2.5s ({p50:.1f}s)")
warn(p95 > 5, f"turn p95 over 5s ({p95:.1f}s)")

if "--fast" not in sys.argv:
    print("═ 5. JUDGE")
    scores, jdt = post("/plan/judge", {
        "pairing": pairing, "transcript": state["history"], "deck": deck_md}, timeout=120)
    if "error" in scores:
        warn(True, f"judge unavailable: {scores}")
    else:
        for k in ("character_fit", "question_quality", "deck_coverage", "emergence", "deck_craft", "flow"):
            v = scores.get(k, 0)
            print(f"  {k:<18} {v}/10")
            check(isinstance(v, (int, float)) and v >= 6, f"{k} ≥ 6")
        print(f"  best:  {scores.get('best_moment')}")
        print(f"  worst: {scores.get('worst_moment')}")
        print(f"  verdict: {scores.get('verdict')}")

print("═══ RESULT:", "PASS" if not fails else f"FAIL ({len(fails)})", f"· {len(warns)} warnings")
sys.exit(0 if not fails else 1)
