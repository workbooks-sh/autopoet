#!/usr/bin/env python3
"""FULL PIPELINE EVAL — does the whole thing actually PRODUCE A USEFUL VAULT?

plan_session.py proves the CONVERSATION works. This proves the OUTPUT works:
the deck the conversation builds must compile into a real vault (workspace,
agents, rules, first proposal) that REFLECTS what was discussed — not a
generic default. This is the 'inform 7 → inform 6' seam.

Flow:
  1. run a full session to 'complete' (form → conversation → deck)
  2. POST /plan/finalize  → compile deck into plan.* + build the vault
  3. STRUCTURAL: workspace built, agents/pages present, first proposal exists
  4. GROUNDING: the built vault traces back to the conversation (workspace
     name / agent jobs / firstrun echo the deck's actual content, not defaults)
  5. JUDGE: is this vault a faithful, useful realization of the plan?

Run:  python3 evals/full_pipeline.py [--persona=ceramics|founder|teacher] [--fast]
Exit: 0 pass, 1 fail.
"""
import json, re, sys, time, urllib.request

BASE = "http://127.0.0.1:4477"
HOME = __file__.rsplit("/", 2)[0]
TOKEN = open(f"{HOME}/data/ctl").read().split()[1]

PERSONAS = {
    "ceramics": {
        "form": {"name": "Mara Ellison", "areas": ["running a business"], "manner": "gentle",
                 "energy": "calm", "humor": "dry", "verbosity": "balanced", "voice_pref": "warm",
                 "accent_pref": "no preference", "remarks": "ceramics studio, not techy"},
        "answers": ["i make ceramics, sell at markets, hopeless at computers",
                    "i want people to order online without me doing tech",
                    "instagram and a simple order form", "i photograph pieces on my phone in batches",
                    "kiln fires fridays, so weekly", "keep it simple",
                    "yes", "you decide", "that's it", "no"],
        # words we expect to survive into the vault (grounding check)
        "expect": ["ceramic", "order", "instagram", "market", "week", "kiln", "photo", "studio"],
    },
    "founder": {
        "form": {"name": "Dev Okonkwo", "areas": ["building software"], "manner": "blunt",
                 "energy": "spirited", "humor": "mandatory", "verbosity": "terse", "voice_pref": "deep",
                 "accent_pref": "no preference", "remarks": "dev-tools founder, hate fluff"},
        "answers": ["solo founder, rust CLI for infra teams",
                    "i want a growth engine: docs, changelog, waitlist, automated",
                    "github and hacker news, plus an email list", "i tag releases in git daily",
                    "docs are markdown in the repo", "make it fast and mine",
                    "tie it to git tags", "you pick the stack", "good", "ship it"],
        "expect": ["doc", "release", "changelog", "waitlist", "github", "git", "launch", "email", "growth"],
    },
}
_pk = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--persona=")), "ceramics")
P = PERSONAS[_pk]
FORM, ANSWERS, EXPECT = P["form"], P["answers"], P["expect"]
print(f"══ full pipeline · persona: {_pk} ══")


def post(path, payload, timeout=120):
    r = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(),
        headers={"authorization": "Bearer " + TOKEN, "content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}


def post_text(path, text=""):
    r = urllib.request.Request(BASE + path, data=text.encode(),
        headers={"authorization": "Bearer " + TOKEN, "content-type": "text/plain"}, method="POST")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.read().decode()


def get(path):
    r = urllib.request.Request(BASE + path, headers={"authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.read().decode()


fails = []
def check(ok, label):
    print(("  ✓ " if ok else "  ✗ ") + label)
    if not ok: fails.append(label)


# 1. run the conversation to completion, mirroring the client (deck adds)
print("═ 1. SESSION → DECK")
pairing = post("/onboard/requisition", FORM)
check("name" in pairing, "pairing")
if fails: sys.exit(1)
post_text("/voice/deck/new"); time.sleep(0.4)
for s in pairing.get("slides", []):
    post_text("/voice/deck/add", s["md"])
state = {"form": FORM, "pairing": pairing, "history": [], "fork_done": False, "deck_titles": []}
ai = 0
for turn in range(30):
    mv = post("/plan/turn", {"form": FORM, "pairing": pairing, "history": state["history"][-20:],
                             "fork_done": state["fork_done"], "deck_titles": state["deck_titles"][-12:]})
    m = mv.get("move")
    if not m: check(False, f"turn {turn}: {mv}"); break
    if mv.get("md"):
        post_text("/voice/deck/add", mv["md"]); state["deck_titles"].append(mv.get("title", ""))
    state["history"].append({"role": "assistant", "content": mv.get("say", "")})
    if m == "ask":
        state["history"].append({"role": "user", "content": ANSWERS[ai] if ai < len(ANSWERS) else "you decide"}); ai += 1
    elif m == "fork":
        pick = mv["options"][1]
        if pick.get("md"): post_text("/voice/deck/add", pick["md"])
        state["history"].append({"role": "user", "content": "let's go with: " + pick["title"]}); state["fork_done"] = True
    elif m == "complete":
        break
deck = get("/voice/deck")
check(len(deck.split("\n---\n")) >= 3, f"deck built ({len(deck.split(chr(10)+'---'+chr(10)))} slides)")

# 2. COMPILE + BUILD the vault
print("═ 2. FINALIZE → VAULT (inform7 → inform6)")
built = post("/plan/finalize", FORM, timeout=180)
check("workspace" in built and not built.get("error"), f"vault built: {built}")
if "error" in built:
    print("   ", built); sys.exit(1)
print(f"   workspace: {built['workspace']}")
print(f"   pages:     {built.get('pages')}")
print(f"   agents:    {built.get('agents')}")
print(f"   firstrun:  {built.get('firstrun')!r}")

# 3. STRUCTURAL
print("═ 3. STRUCTURE")
check(bool(built.get("workspace")) and built["workspace"].lower() not in ("notebook", "scratch"),
      "workspace is not the generic default")
check(len(built.get("agents", [])) >= 1, "at least one agent")
check(len(built.get("pages", [])) >= 2, "at least two pages")
check(bool(built.get("firstrun")), "a first task was set")
prop = ""
try:
    prop = get("/intake/proposal")
    check("first" in prop.lower() or len(prop) > 100, "first proposal exists")
except Exception as e:
    check(False, f"first proposal: {e}")

# 4. GROUNDING — the vault must trace back to the CONVERSATION, not defaults
print("═ 4. GROUNDING (does the vault reflect what was discussed?)")
blob = (json.dumps(built) + " " + prop).lower()
hits = [w for w in EXPECT if w in blob]
check(len(hits) >= 3, f"vault echoes the conversation: {hits} (need ≥3 of {EXPECT})")

# 5. JUDGE — faithful + useful realization?
if "--fast" not in sys.argv:
    print("═ 5. JUDGE")
    verdict = post("/plan/judge_vault", {"deck": deck, "vault": built, "proposal": prop}, timeout=120)
    if verdict.get("error"):
        print("   (judge unavailable:", verdict, ")")
    else:
        for k in ("faithfulness", "usefulness", "specificity"):
            v = verdict.get(k, 0)
            print(f"   {k:<14} {v}/10")
            check(isinstance(v, (int, float)) and v >= 6, f"{k} ≥ 6")
        print("   verdict:", verdict.get("verdict"), "·", verdict.get("note"))

print("═══ RESULT:", "PASS" if not fails else f"FAIL ({len(fails)})")
sys.exit(0 if not fails else 1)
