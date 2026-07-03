// AutopoetQuiz — the "set up your nexus" flow that ends onboarding.
//
// A STATE-MACHINE interview, not a form. Three chapters: WHAT YOU WANT
// (intent → domain probes → platform chips → industry → aspirations), HOW YOU
// WORK (skill-gated spines: coder / learner / civilian), THE RULES (leash,
// pings, failure posture, per-world extras). Every answer posts to
// /profile/set as it lands, and at the end the answers COMPILE into a plan —
// workspaces, agents, first rules, connect order, settings — persisted as
// plan.* lines the brain runs at first dashboard load.
//
// Widgets: cards (lottie line-art; hover loops, mouse-out freezes in place,
// re-hover resumes — never restarts), chip multi-pick with search, searchable
// single-pick with custom entry, chapter interstitials, and an intro screen
// that replaces "skip" with an honest pitch. Every question takes optional
// NOTES (press n): typed or dictated — dictation is Moonshine, fully local,
// via POST /voice/dictate.
//
// Deliberately its OWN file: app.html supplies only the container + hooks
// (post / postRaw / createFace / refreshIcons / onDone). gsap + lucide +
// lottie are globals.
(() => {
  const CSS = `
  #obquiz { display:none; flex-direction:column; align-items:center; gap:18px;
    width:auto; max-width:860px; padding:40px; position:relative;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .qzface { width:64px; height:64px; border-radius:15px; border:1px solid rgba(0,0,0,.12);
    background:#fff; overflow:hidden; flex:none; }
  .qzhead { text-align:center; max-width:460px; }
  .qzkicker { font:10.5px ui-monospace,monospace; color:#b3bac4; letter-spacing:.08em; }
  .qztitle { font:600 19px ui-monospace,monospace; color:#1c2230; margin-top:7px; }
  .qzsub { font:12px/1.6 ui-monospace,monospace; color:#67707c; margin:7px 0 0; }
  .qzmeta { font:11px ui-monospace,monospace; color:#b3bac4; margin-top:10px; }
  .qzcards { display:flex; flex-wrap:wrap; gap:12px; justify-content:center; width:100%; }
  /* up to five options: ONE row, always — cards shrink instead of wrapping */
  .qzcards.row { flex-wrap:nowrap; }
  .qzcards.row .qzcard { flex:1 1 0; width:auto; max-width:158px; min-width:126px; }
  .qzcard { position:relative; display:flex; flex-direction:column; align-items:center;
    gap:4px; width:158px; padding:14px 12px 13px; box-sizing:border-box;
    border:1px solid #d6dbe2; border-radius:16px; background:#fff; cursor:pointer;
    -webkit-app-region:no-drag; transition:border-color .16s ease, box-shadow .16s ease; }
  .qzcard:hover { border-color:#b9c2cd; box-shadow:0 1px 4px rgba(25,35,55,.1); }
  .qzcard.on { border-color:#6aa84f; box-shadow:0 0 0 3px rgba(106,168,79,.12); }
  .qzcard .qzlot { width:96px; height:96px; pointer-events:none; }
  .qzcard img.qzmic { width:44px; height:44px; margin:22px 0 26px; pointer-events:none; }
  .qzcard .qzglyph { width:30px; height:30px; margin:28px 0 30px; color:#3a4250; }
  .qzcard .qzglyph svg { width:30px; height:30px; }
  .qzname { font:600 12.5px ui-monospace,monospace; color:#1c2230; }
  .qzline { font:10.5px/1.45 ui-monospace,monospace; color:#67707c; text-align:center; min-height:29px; }
  .qzck { position:absolute; top:9px; right:9px; display:none; color:#6aa84f; }
  .qzck svg { width:15px; height:15px; }
  .qzcard.on .qzck { display:block; }
  /* chip multi-pick (platforms, aspirations) */
  .qzchipgrid { display:flex; flex-wrap:wrap; gap:9px; justify-content:center; max-width:520px; }
  .qzchip2 { display:flex; align-items:center; gap:7px; font:12px ui-monospace,monospace;
    color:#1c2230; background:#fff; border:1px solid #d6dbe2; border-radius:999px;
    padding:7px 14px; cursor:pointer; -webkit-app-region:no-drag;
    transition:border-color .14s ease, box-shadow .14s ease, background .14s ease; }
  .qzchip2:hover { border-color:#b9c2cd; }
  .qzchip2.on { border-color:#6aa84f; background:#f4faf1; box-shadow:0 0 0 2px rgba(106,168,79,.10); }
  .qzchip2.none { border-style:dashed; color:#67707c; }
  .qzchipline { font:10.5px ui-monospace,monospace; color:#9aa2ad; max-width:460px; text-align:center; min-height:14px; }
  .qzsearch { font:12.5px ui-monospace,monospace; color:#1c2230; padding:8px 12px;
    border:1px solid #d6dbe2; border-radius:10px; background:#fff; outline:none;
    width:300px; -webkit-app-region:no-drag; }
  .qzsearch:focus { border-color:#8e7cc3; box-shadow:0 0 0 3px rgba(142,124,195,.14); }
  /* searchable single-pick rows (industry) */
  .qzrows { display:flex; flex-direction:column; gap:6px; width:340px; max-height:238px; overflow-y:auto; }
  .qzrow { font:12.5px ui-monospace,monospace; color:#1c2230; text-align:left; background:#fff;
    border:1px solid #e4e8ee; border-radius:10px; padding:9px 13px; cursor:pointer;
    -webkit-app-region:no-drag; transition:border-color .14s ease; }
  .qzrow:hover { border-color:#b9c2cd; }
  .qzrow.custom { color:#8e7cc3; }
  /* nav + notes */
  .qznav { display:flex; align-items:center; gap:14px; min-height:34px; }
  .qzback { display:flex; align-items:center; justify-content:center; width:30px; height:30px;
    border:1px solid #d6dbe2; border-radius:9px; background:#fff; color:#67707c;
    cursor:pointer; -webkit-app-region:no-drag; }
  .qzback:hover { border-color:#b9c2cd; color:#1c2230; }
  .qzback svg { width:15px; height:15px; }
  .qznotebtn { font:11px ui-monospace,monospace; color:#98a0ac; background:none; border:none;
    cursor:pointer; -webkit-app-region:no-drag; }
  .qznotebtn:hover { color:#3a4250; }
  .qznotebtn .qzdot { display:inline-block; width:6px; height:6px; border-radius:3px;
    background:#6aa84f; margin-left:5px; vertical-align:1px; }
  .qzbar { width:120px; height:3px; border-radius:2px; background:#e4e8ee; overflow:hidden; }
  .qzbarfill { height:100%; width:0; border-radius:2px; background:#8e7cc3; }
  .qzgo { font:12.5px ui-monospace,monospace; padding:8px 17px; border-radius:10px;
    border:1px solid #2f6fdd; background:#2f6fdd; color:#fff; cursor:pointer;
    -webkit-app-region:no-drag; }
  .qzgo:hover { background:#245cc0; }
  .qzgo:disabled { border-color:#d6dbe2; background:#eef1f5; color:#b3bac4; cursor:default; }
  .qzlater { font:11px ui-monospace,monospace; color:#98a0ac; background:none; border:none;
    cursor:pointer; -webkit-app-region:no-drag; margin-top:2px; }
  .qzlater:hover { color:#3a4250; }
  .qzhint { font:10.5px ui-monospace,monospace; color:#c5ccd6; }
  .qznotes { width:480px; border:1px solid #e4e8ee; border-radius:14px; background:#fafbfc;
    padding:12px; display:flex; gap:10px; align-items:stretch; position:relative; }
  .qznotes textarea { flex:1; min-height:74px; resize:none; font:12px/1.55 ui-monospace,monospace;
    color:#1c2230; border:none; background:none; outline:none; }
  .qzdictate { align-self:flex-end; font:11px ui-monospace,monospace; color:#3a4250;
    border:1px solid #d6dbe2; border-radius:9px; background:#fff; padding:7px 12px;
    cursor:pointer; white-space:nowrap; -webkit-app-region:no-drag; }
  .qzdictate:hover { border-color:#b9c2cd; }
  .qzdictate.rec { color:#c0392b; border-color:#e6b0aa; }
  .qznoted { position:absolute; right:12px; bottom:8px; font:10.5px ui-monospace,monospace;
    color:#6aa84f; opacity:0; }
  /* finale plan */
  .qzplan { display:flex; flex-direction:column; gap:7px; width:480px; }
  .qzplanrow { display:flex; gap:10px; font:11.5px/1.5 ui-monospace,monospace; color:#3a4250;
    background:#fff; border:1px solid #e4e8ee; border-radius:10px; padding:8px 12px; text-align:left; }
  .qzplanrow b { color:#8e7cc3; font-weight:600; flex:none; width:84px; }
  .qzplanrow.run { border-color:#6aa84f; background:#f4faf1; }
  .qzplanrow.run b { color:#4d7d3a; }
  `;

  const lot = n => ({ lot: n });
  const mic = n => ({ mic: n });
  const gly = n => ({ gly: n });

  // ── platform catalogs (chips) — keyed by the road that triggers them ────────
  const CATALOGS = {
    sell: ["shopify", "etsy", "amazon", "stripe", "square", "paypal", "ebay", "gumroad", "woocommerce", "printful", "faire", "big cartel"],
    audience: ["instagram", "tiktok", "youtube", "x (twitter)", "substack", "linkedin", "meta ads", "discord", "patreon", "twitch", "newsletters", "pinterest"],
    freelance: ["linkedin", "upwork", "fiverr", "calendly", "notion", "quickbooks", "stripe", "contra", "dribbble", "google workspace"],
    trade: ["robinhood", "coinbase", "fidelity", "schwab", "tradingview", "webull", "binance", "vanguard", "kraken", "metamask / defi"],
    business: ["google workspace", "sheets / excel", "quickbooks", "canva", "square", "shopify", "mailchimp", "slack", "wix / squarespace", "meta business suite", "hubspot"],
    productivity: ["gmail", "google calendar", "google drive", "sheets / excel", "notion", "outlook", "slack", "apple notes", "dropbox", "trello", "todoist", "quickbooks"],
    site: ["wordpress", "squarespace", "wix", "canva", "google sites", "shopify", "webflow", "carrd", "ghost", "framer"],
    tool: ["sheets / excel", "notion", "airtable", "zapier", "figma", "github", "bubble / glide", "vs code", "retool", "supabase"],
    game: ["roblox", "minecraft", "unity", "scratch", "godot", "itch.io", "unreal", "gamemaker", "steam", "pico-8"],
    delegate: ["gmail", "google drive", "google calendar", "slack", "sheets / excel", "notion", "chatgpt / claude", "x (twitter)", "discord", "github", "zapier"],
  };
  const catKey = s => {
    if (s.build_what === "store" || s.money_road === "sell") return "sell";
    if (s.money_road === "audience") return "audience";
    if (s.money_road === "freelance") return "freelance";
    if (s.money_road === "trade") return "trade";
    if (s.money_road === "business") return "business";
    if (s.intent === "productivity") return "productivity";
    if (s.build_what === "site") return "site";
    if (s.build_what === "tool") return "tool";
    if (s.build_what === "game") return "game";
    return "delegate";
  };

  const INDUSTRIES = [
    ["ecommerce", "selling online"], ["retail", "retail (physical shop)"], ["finance", "finance & money"],
    ["health", "health & medicine"], ["fitness", "fitness & wellness"], ["education", "education & teaching"],
    ["realestate", "real estate"], ["legal", "legal"], ["media", "media & news"], ["music", "music"],
    ["film", "film & video"], ["games", "games"], ["art", "art & design"], ["writing", "writing & publishing"],
    ["marketing", "marketing & agencies"], ["software", "software & tech"], ["restaurants", "restaurants & food"],
    ["construction", "construction & trades"], ["manufacturing", "manufacturing"], ["logistics", "logistics & transport"],
    ["travel", "travel & hospitality"], ["events", "events"], ["nonprofit", "nonprofits"], ["beauty", "beauty"],
    ["none", "not really an industry. just me."],
  ];

  // ── the graph — three chapters; next() routes on state ──────────────────────
  const afterGit = s => (s.speak === "fluent" ? "pen" : "narrate");
  const addon = s => {
    if (s.intent === "delegate") return "hours";
    if (s.intent === "build") return s.speak === "fluent" ? "taste" : "start";
    if (s.intent === "money") return "moneyrules";
    return null;
  };
  const NODES = {
    intro: { widget: "intro", next: () => "intent" },

    // ── part 1: what you want ────────────────────────────────────────────────
    intent: {
      title: "what brings you here?",
      sub: "pick the closest one. you can do all of it later.",
      options: [
        { v: "blank", name: "just looking around", line: "no agenda is a valid agenda.", ...lot("plant-pot") },
        { v: "build", name: "build an app or website", line: "you describe it, it exists.", ...lot("hammer") },
        { v: "money", name: "make money", line: "the honest answer.", ...lot("cashier-machine") },
        { v: "productivity", name: "get my life organized", line: "inbox, calendar, paperwork — tamed.", ...lot("weather-calendar") },
        { v: "delegate", name: "put ai to work", line: "it grinds while you don't.", ...lot("delivery-boy") },
      ],
      next: s => ({ blank: "blank_nudge", build: "build_what", money: "money_road",
                    productivity: "prod_pain", delegate: "delegate_job" }[s.intent]),
    },
    blank_nudge: {
      title: "want a nudge, or left alone?",
      sub: "both are respected here.",
      options: [
        { v: "demo", name: "show me something cool", line: "a world that already works.", ...lot("gaming-device") },
        { v: "idea", name: "i have a half-formed idea", line: "half-formed is our specialty.", ...lot("mixing-bowl") },
        { v: "alone", name: "let me poke around", line: "no tour, no tooltips.", ...lot("camping-van") },
        { v: "surprise", name: "surprise me", line: "bold. noted.", ...lot("baby-elephant") },
      ],
      next: () => "industry",
    },
    build_what: {
      title: "what are we making?",
      sub: "roughly. blueprints come later.",
      options: [
        { v: "site", name: "a website", line: "portfolio, landing page, the works.", ...lot("online-store") },
        { v: "store", name: "an online store", line: "things go in cart, money comes out.", ...lot("online-shopping") },
        { v: "tool", name: "an app or tool", line: "the thing nobody built for you yet.", ...lot("glue-gun") },
        { v: "game", name: "a game", line: "respect.", ...lot("ludo-board") },
        { v: "unsure", name: "i'll know it when i see it", line: "we'll wander together.", ...lot("travel-compass") },
      ],
      next: s => ({ site: "build_site_job", store: "money_sell_what", tool: "build_tool_who",
                    game: "platforms", unsure: "industry" }[s.build_what]),
    },
    build_site_job: {
      title: "what should it actually do?",
      sub: "besides look good. that part's free.",
      options: [
        { v: "look", name: "just look good", line: "a fair ask.", ...lot("facial") },
        { v: "bookings", name: "take bookings", line: "appointments, without the back-and-forth.", ...lot("chairlift") },
        { v: "sell", name: "sell things", line: "a shop in site's clothing.", ...lot("card-discount") },
        { v: "signups", name: "collect signups", line: "emails first, everything later.", ...lot("sale-announcement") },
        { v: "publish", name: "publish my writing", line: "a home for the words.", ...lot("research-paper") },
      ],
      next: () => "platforms",
    },
    build_tool_who: {
      title: "who's going to use it?",
      sub: "changes how bulletproof it needs to be.",
      options: [
        { v: "me", name: "just me", line: "the best customer.", ...lot("slippers") },
        { v: "team", name: "my team", line: "small audience, high stakes.", ...lot("friends-playing") },
        { v: "customers", name: "my customers", line: "now it has to be nice.", ...lot("pet-cafe") },
        { v: "world", name: "the whole internet", line: "bold. we'll harden it.", ...lot("aeroplane") },
      ],
      next: () => "platforms",
    },
    money_road: {
      title: "which road?",
      sub: "money has lanes. pick yours.",
      options: [
        { v: "sell", name: "sell products", line: "make thing, list thing, ship thing.", ...lot("grocery-bag") },
        { v: "audience", name: "build an audience", line: "attention first, money follows.", ...lot("annocument") },
        { v: "freelance", name: "sell my services", line: "you're the product. premium one.", ...lot("scissors") },
        { v: "trade", name: "trade or invest", line: "numbers go up. sometimes.", ...lot("thunderstorm") },
        { v: "business", name: "grow my business", line: "the grown-up answer.", ...lot("planting-tree") },
      ],
      next: s => ({ sell: "money_sell_what", audience: "money_audience_medium", freelance: "money_freelance_craft",
                    trade: "money_trade_flavor", business: "money_biz_bottleneck" }[s.money_road]),
    },
    money_sell_what: {
      title: "selling what?",
      sub: "the honest version, not the pitch deck.",
      options: [
        { v: "physical", name: "physical stuff", line: "real boxes, real shipping.", ...lot("travel-bag") },
        { v: "digital", name: "digital downloads", line: "make once, sell forever.", ...lot("vr-controller") },
        { v: "subs", name: "subscriptions", line: "the gift that keeps billing.", ...lot("weather-app") },
        { v: "pod", name: "print-on-demand", line: "your art, someone else's warehouse.", ...lot("gym-cloth") },
        { v: "unsure", name: "don't know yet", line: "just know i want a store.", ...lot("travel-compass") },
      ],
      next: () => "platforms",
    },
    money_audience_medium: {
      title: "what do you make?",
      sub: "the thing the audience shows up for.",
      options: [
        { v: "video", name: "video", line: "the algorithm's favorite child.", ...lot("camera") },
        { v: "writing", name: "writing", line: "words, the durable medium.", ...lot("crayon-box") },
        { v: "audio", name: "audio / podcast", line: "voices in people's heads.", ...lot("saxophone") },
        { v: "art", name: "art / design", line: "pictures worth posting.", ...lot("painting") },
        { v: "zero", name: "nothing yet", line: "everyone started from zero. once.", ...lot("planter") },
      ],
      next: () => "platforms",
    },
    money_freelance_craft: {
      title: "what do you sell hours of?",
      sub: "the craft. the admin around it gets automated.",
      options: [
        { v: "design", name: "design", line: "taste, invoiced.", ...lot("color-palette") },
        { v: "writing", name: "writing", line: "deadlines and drafts.", ...lot("writing") },
        { v: "code", name: "code", line: "hourly rate, exponential output.", ...lot("gaming-computer") },
        { v: "marketing", name: "marketing", line: "other people's growth charts.", ...lot("sale-announcement") },
        { v: "consulting", name: "consulting", line: "advice, professionally.", ...lot("reflector") },
        { v: "hands", name: "hands-on work", line: "photo, repair, trades. real work.", ...lot("wood-craving") },
      ],
      next: () => "platforms",
    },
    money_trade_flavor: {
      title: "what flavor?",
      sub: "this mostly decides how many alerts you get.",
      options: [
        { v: "stocks", name: "stocks", line: "the classic.", ...lot("chess-game") },
        { v: "crypto", name: "crypto", line: "sleep is for fiat.", ...lot("torch") },
        { v: "options", name: "the spicy stuff", line: "we'll set alerts. lots of alerts.", ...lot("racing-game") },
        { v: "index", name: "the boring long game", line: "statistically the winner.", ...lot("beach-chair") },
        { v: "watch", name: "just want to watch", line: "learn first, leap later.", ...lot("weather-location") },
      ],
      next: () => "platforms",
    },
    money_biz_bottleneck: {
      title: "what's the bottleneck?",
      sub: "the thing that, fixed, changes everything.",
      options: [
        { v: "customers", name: "not enough customers", line: "the eternal one.", ...lot("pet-cafe") },
        { v: "admin", name: "too much admin", line: "drowning in the boring parts.", ...lot("cleaning-trolley") },
        { v: "presence", name: "no online presence", line: "invisible, professionally.", ...lot("online-store") },
        { v: "numbers", name: "can't see my numbers", line: "flying blind is a strategy. a bad one.", ...lot("fitness-tracker") },
        { v: "all", name: "honestly, all of it", line: "we'll triage.", ...lot("dustbin") },
      ],
      next: () => "platforms",
    },
    prod_pain: {
      title: "what's eating your time?",
      sub: "the thing you'd pay to never do again.",
      options: [
        { v: "inbox", name: "email and messages", line: "the hydra. reply to one, three appear.", ...lot("weather-alert") },
        { v: "calendar", name: "scheduling chaos", line: "double-booked, again.", ...lot("appointment-schedule") },
        { v: "paperwork", name: "invoices and forms", line: "red tape, by the spool.", ...lot("thread-spool") },
        { v: "scattered", name: "notes everywhere", line: "seven versions of everything.", ...lot("makeup-pouch") },
        { v: "people", name: "coordinating people", line: "herding, professionally.", ...lot("parent-support") },
        { v: "all", name: "all of it", line: "we'll triage.", ...lot("dustbin") },
      ],
      next: () => "prod_scope",
    },
    prod_scope: {
      title: "organizing for who?",
      sub: "changes what gets shared, and with whom.",
      options: [
        { v: "me", name: "just me", line: "a party of one.", ...lot("slippers") },
        { v: "family", name: "me plus family", line: "the hardest org chart.", ...lot("mother-love") },
        { v: "team", name: "a small team", line: "everyone sees the board.", ...lot("friends-playing") },
        { v: "business", name: "a whole business", line: "the works.", ...lot("welfare-house") },
      ],
      next: () => "platforms",
    },
    delegate_job: {
      title: "what should the robots take off your plate?",
      sub: "they don't get bored. use that.",
      options: [
        { v: "watch", name: "keep an eye on things", line: "inbox, markets, mentions — what matters.", ...lot("cat") },
        { v: "research", name: "dig and report back", line: "wake up to answers instead of tabs.", ...lot("research-paper") },
        { v: "produce", name: "make things on schedule", line: "relentlessly on time.", ...lot("mixing-batter") },
        { v: "grind", name: "do the busywork", line: "data entry, follow-ups, filing. gone.", ...lot("kettlebells") },
      ],
      next: () => "platforms",
    },
    platforms: {
      widget: "pick",
      title: "which of these do you live in?",
      sub: "tap everything you actually use. it'll meet you there.",
      options: s => CATALOGS[catKey(s)].map(p => ({ v: p.replace(/[^a-z0-9]+/g, "-"), name: p })),
      next: () => "industry",
    },
    industry: {
      widget: "search",
      title: "what world are you from?",
      sub: "so it talks like your industry, not like a startup.",
      options: () => INDUSTRIES.map(([v, label]) => ({ v, name: label })),
      next: () => "aspirations",
    },
    aspirations: {
      widget: "pick",
      title: "cool things you want ai to do for you",
      sub: "check anything. these quietly become real machinery.",
      options: () => [
        { v: "inbox", name: "watch my inbox and deal with it" },
        { v: "website", name: "build me a website" },
        { v: "paperwork", name: "automate my paperwork" },
        { v: "research", name: "run research while i sleep" },
        { v: "teamtools", name: "build tools for my team" },
        { v: "publish", name: "publish content on a schedule" },
        { v: "ghost", name: "learn my style and write like me" },
        { v: "watch", name: "watch numbers and alert me" },
        { v: "organize", name: "keep my files organized" },
        { v: "receipts", name: "keep receipts on everything it does" },
      ],
      next: () => "ch2",
    },

    // ── part 2: how you work ─────────────────────────────────────────────────
    ch2: { widget: "chapter", part: "part 2 of 3", title: "how you work.",
           line: "tools, habits, and how much it should explain itself.",
           next: () => "speak" },
    speak: {
      title: "do you speak code?",
      sub: "no wrong answer. the machine adjusts its accent.",
      options: [
        { v: "fluent", name: "fluently", line: "i dream in stack traces.", ...lot("gaming-computer") },
        { v: "some", name: "a little", line: "i can read it, mostly.", ...lot("basic-learning") },
        { v: "none", name: "not a word", line: "that's the machine's job.", ...lot("creative-idea") },
      ],
      next: s => (s.speak === "fluent" ? "language" : s.speak === "some" ? "git" : "watch"),
    },
    language: {
      title: "pick your poison",
      sub: "the nexus speaks every language. this one it speaks back to you.",
      options: [
        { v: "rust", name: "rust", line: "a cargo cultist. welcome.", ...mic("rust") },
        { v: "typescript", name: "typescript", line: "types are a love language.", ...mic("typescript") },
        { v: "python", name: "python", line: "whitespace believer.", ...mic("python") },
        { v: "elixir", name: "elixir", line: "let it crash.", ...mic("elixir") },
        { v: "go", name: "go", line: "boring on purpose.", ...mic("go") },
        { v: "javascript", name: "javascript", line: "chaos, but familiar.", ...mic("javascript") },
      ],
      next: () => "git",
    },
    git: {
      title: "how do you git?",
      sub: "if you have laws, the machine keeps them. on every change, forever.",
      options: [
        { v: "strict", name: "my way, exactly", line: "conventions are law.", ...lot("gps-navigator") },
        { v: "tidy", name: "keep it clean", line: "small commits, clear messages.", ...lot("broom") },
        { v: "vibes", name: "git happens", line: "history is a suggestion.", ...lot("gaming-error") },
      ],
      next: s => (s.git === "strict" ? "gitrules" : afterGit(s)),
    },
    gitrules: {
      title: "which laws?",
      sub: "pick any. these get enforced — not suggested — on every change.",
      multi: true,
      options: [
        { v: "conventional-commits", name: "conventional commits", line: "feat: fix: chore:", ...gly("git-commit") },
        { v: "branch-per-task", name: "one branch per task", line: "no drive-by changes.", ...gly("git-branch") },
        { v: "rebase-only", name: "rebase, never merge", line: "history is a straight line.", ...gly("git-merge") },
        { v: "tests-before-push", name: "tests before push", line: "red, green, then go.", ...gly("flask-conical") },
      ],
      next: afterGit,
    },
    pen: {
      title: "who holds the pen?",
      sub: "when the machine writes code, who gets to call it committed.",
      options: [
        { v: "branch-pr", name: "branch and propose", line: "it opens, you merge.", ...lot("pen-tool") },
        { v: "stage", name: "stage only", line: "leaves it in the tree.", ...lot("notepad") },
        { v: "commit", name: "it commits", line: "co-author trailer, honest history.", ...lot("ink-pen") },
        { v: "readonly", name: "never touch git", line: "the braid is yours.", ...lot("chest-guard") },
      ],
      next: () => "fence",
    },
    fence: {
      title: "where does the fence go?",
      sub: "pick what it never edits alone. everything else is fair game.",
      multi: true,
      options: [
        { v: "deps", name: "deps and lockfiles", line: "every dependency is a hire.", ...gly("package") },
        { v: "ci", name: "ci and release config", line: "the pipeline is law.", ...gly("settings") },
        { v: "secrets", name: "secrets and env", line: "obviously.", ...gly("lock") },
        { v: "nothing", name: "nothing is sacred", line: "brave. noted.", ...gly("flame") },
      ],
      next: () => "trust",
    },
    trust: {
      title: "new work appears. when do you trust it?",
      sub: "this decides what the machine shows you first.",
      options: [
        { v: "tests", name: "tests first", line: "red, green, believe.", ...lot("thermometer") },
        { v: "examples", name: "show me examples", line: "seeing is believing.", ...lot("binoculars") },
        { v: "run-it", name: "i'll just run it", line: "faith-based engineering.", ...lot("paragliding") },
      ],
      next: () => "research",
    },
    research: {
      title: "before building something new?",
      sub: "how much of the map do you want first?",
      options: [
        { v: "deep", name: "read everything", line: "then begin.", ...lot("bookshelf") },
        { v: "skim", name: "a quick look", line: "enough to not reinvent it.", ...lot("map") },
        { v: "greenfield", name: "just build", line: "the field is greener untouched.", ...lot("forest") },
      ],
      next: () => "ch3",
    },
    narrate: {
      title: "should the machine narrate?",
      sub: "it can explain every move while it works, or keep quiet.",
      options: [
        { v: "teach", name: "narrate everything", line: "every move, plain words.", ...lot("mic") },
        { v: "highlights", name: "just the good parts", line: "only the interesting bits.", ...lot("spotlight") },
        { v: "quiet", name: "just do it", line: "you'll ask when curious.", ...lot("headphones") },
      ],
      next: s => (s.narrate === "quiet" ? "firstwin" : "depth"),
    },
    depth: {
      title: "how deep should explanations go?",
      sub: "when it explains, pick the altitude.",
      options: [
        { v: "eli5", name: "like i'm five", line: "analogies, no scary words.", ...lot("happy-kid") },
        { v: "code", name: "point at the code", line: "show the actual lines.", ...lot("e-learning") },
        { v: "both", name: "analogy, then code", line: "warm up, then the real thing.", ...lot("knowledge") },
      ],
      next: () => "firstwin",
    },
    firstwin: {
      title: "what counts as a first win?",
      sub: "the first session ends when this happens.",
      options: [
        { v: "visible", name: "something on screen", line: "a node lights up. you grin.", ...lot("arcade-game") },
        { v: "automated", name: "a chore automated", line: "the machine does the boring thing.", ...lot("dishwasher") },
        { v: "understood", name: "something understood", line: "you walk away smarter.", ...lot("graduation-cap") },
      ],
      next: () => "ch3",
    },
    watch: {
      title: "what may it read?",
      sub: "it works better with eyes. they're your eyes.",
      options: [
        { v: "mail", name: "my email", line: "read yes, send no.", ...lot("parachute-delivery") },
        { v: "files", name: "my files", line: "docs, sheets, the drive.", ...lot("medical-record") },
        { v: "both", name: "the lot", line: "email and files, read-only.", ...lot("grocery-basket") },
        { v: "none", name: "nothing yet", line: "earn it first.", ...lot("scuba-mask") },
      ],
      next: s => (s.watch === "none" ? "voice" : "offlimits"),
    },
    offlimits: {
      title: "anything off-limits?",
      sub: "some things it should never read — not even to help.",
      options: [
        { v: "payroll", name: "payroll and hr", line: "paychecks are sacred.", ...lot("billing-system") },
        { v: "personal", name: "personal threads", line: "family, doctors, the accountant.", ...lot("photo-frame") },
        { v: "clients", name: "client financials", line: "their numbers stay theirs.", ...lot("donation-box") },
        { v: "nothing", name: "nothing off-limits", line: "it all stays on this machine anyway.", ...lot("sunglasses") },
      ],
      next: () => "voice",
    },
    voice: {
      title: "how should it talk to you?",
      sub: "pick a voice you won't dread reading.",
      options: [
        { v: "plain", name: "plain english", line: "like a sharp assistant.", ...lot("crayon-box") },
        { v: "short", name: "bullet points", line: "headlines only, no essays.", ...lot("stationery-holder") },
        { v: "warm", name: "friendly", line: "a little charm is fine.", ...lot("teacup") },
      ],
      next: () => "ch3",
    },

    // ── part 3: the rules ────────────────────────────────────────────────────
    ch3: { widget: "chapter", part: "part 3 of 3", title: "the rules.",
           line: "the lines it never crosses without you.",
           next: s => (s.speak === "fluent" ? "pings" : "leash") },
    leash: {
      title: "how long is the leash?",
      sub: "how much it may do before checking with you.",
      options: [
        { v: "ask", name: "always ask", line: "nothing happens without a nod.", ...lot("butler-bell") },
        { v: "fenced", name: "free inside the fence", line: "act within limits, ask past them.", ...lot("pet-house") },
        { v: "loose", name: "off the leash", line: "act now, confess in the log.", ...lot("hot-balloon") },
      ],
      next: () => "pings",
    },
    pings: {
      title: "when may it interrupt you?",
      sub: "your attention is the scarcest budget.",
      options: [
        { v: "live", name: "ping me live", line: "every event, as it happens.", ...lot("radio-music") },
        { v: "digest", name: "one daily note", line: "everything, once, with coffee.", ...lot("moka-pot") },
        { v: "fires", name: "emergencies only", line: "silence means all clear.", ...lot("first-aid") },
      ],
      next: () => "oops",
    },
    oops: {
      title: "when something breaks?",
      sub: "and something will. everything here can be undone.",
      options: [
        { v: "freeze", name: "stop and confess", line: "freeze and come get you.", ...lot("winter-jacket") },
        { v: "revert", name: "put it back", line: "undo to last good, then ask.", ...lot("mop-bucket") },
        { v: "quiet", name: "fix it quietly", line: "retry, tell you after.", ...lot("spray-bottle") },
      ],
      next: addon,
    },
    hours: {
      title: "when does the fleet run?",
      sub: "machines don't sleep. you do.",
      options: [
        { v: "always", name: "always on", line: "work never stops.", ...lot("gaming-setup") },
        { v: "nights", name: "while you sleep", line: "wake up to finished work.", ...lot("bedroll") },
        { v: "summoned", name: "only when summoned", line: "idle until you say go.", ...lot("joystick") },
      ],
      next: () => "burn",
    },
    burn: {
      title: "pick a burn ceiling",
      sub: "a hard cap, set before anything runs.",
      options: [
        { v: "pocket", name: "pocket change", line: "a few dollars a day.", ...lot("banana") },
        { v: "line-item", name: "a real line item", line: "predictable monthly spend.", ...lot("appointment-schedule") },
        { v: "fuel", name: "spend to win", line: "outcomes first, invoice later.", ...lot("campsite-fire") },
      ],
      next: () => null,
    },
    start: {
      title: "where do ideas live first?",
      sub: "before it's real, it's somewhere.",
      options: [
        { v: "sketch", name: "napkin first", line: "you draw it, it builds it.", ...lot("digital-drawing") },
        { v: "reference", name: "i bring receipts", line: "links, screenshots, stolen beauty.", ...lot("camera") },
        { v: "words", name: "i can describe it", line: "adjectives until something clicks.", ...lot("thread-spool") },
        { v: "options", name: "show me things", line: "you know it when you see it.", ...lot("color-palette") },
      ],
      next: () => "taste",
    },
    taste: {
      title: "how loud should it look?",
      sub: "your default, not your only setting.",
      options: [
        { v: "whisper", name: "quiet and minimal", line: "whitespace does the work.", ...lot("singing-bowl") },
        { v: "measured", name: "restrained but warm", line: "calm, with a pulse.", ...lot("flower-plant") },
        { v: "loud", name: "expressive", line: "big type, zero apologies.", ...lot("saxophone") },
        { v: "depends", name: "per project", line: "read the room every time.", ...lot("dropper-tool") },
      ],
      next: () => "motion",
    },
    motion: {
      title: "should things move?",
      sub: "the animation budget, roughly.",
      options: [
        { v: "still", name: "barely", line: "a fade, on a good day.", ...lot("beach-chair") },
        { v: "purposeful", name: "only with purpose", line: "motion explains, never decorates.", ...lot("pottery-wheel") },
        { v: "alive", name: "everything breathes", line: "springs, easing, small delights.", ...lot("beach-ball") },
      ],
      next: () => null,
    },
    moneyrules: {
      title: "and when money's involved?",
      sub: "because money mistakes sting the most.",
      options: [
        { v: "never", name: "never touch money", line: "not even to look.", ...lot("boxing-gloves") },
        { v: "read", name: "read and add up", line: "totals, due dates, that's it.", ...lot("glucose-meter") },
        { v: "flag", name: "flag what's off", line: "over budget, double-billed, weird.", ...lot("forecast-reporting") },
        { v: "chase", name: "draft the chasers", line: "late-payer nudges, you send them.", ...lot("car-tracker") },
      ],
      next: () => null,
    },
  };
  const START = "intro";

  // ── the plan compiler — answers cash out as a first-load world ──────────────
  function planFor(s) {
    const asp = (s.aspirations || "").split(",").filter(Boolean);
    let ws, agents = [], rules = [], connect = [], firstrun = "";
    const road = s.money_road;
    if (s.intent === "money") {
      ws = { sell: ["shop", "orders, listings, money watch"],
             audience: ["studio", "content, calendar, audience watch"],
             freelance: ["practice", "clients, portfolio, invoices"],
             trade: ["terminal", "watchlist, alerts, journal"],
             business: ["office", "customers, admin, numbers"] }[road] || ["shop", "orders, money watch"];
      agents = { sell: [["shopkeeper", "watches orders and stock, drafts listings"],
                        ["bookkeeper", "reconciles payouts against orders nightly"]],
                 audience: [["producer", "drafts posts in your voice, keeps the calendar full"]],
                 freelance: [["front desk", "chases invoices, preps client briefs"]],
                 trade: [["lookout", "watches your list, alerts on real moves"]],
                 business: [["operator", "clears the admin pile, keeps numbers current"]] }[road] || [];
      rules = { sell: ["when an order lands, log it and update today's tally"],
                audience: ["every week, draft the next post in my voice"],
                freelance: ["when an invoice email lands, check it against budget, warn me"],
                trade: ["when a watched number moves hard, alert me once"],
                business: ["when an invoice email lands, check it against budget, warn me"] }[road] || [];
      connect = { sell: ["shopify", "gmail", "stripe"], audience: ["instagram", "gmail"],
                  freelance: ["gmail", "stripe"], trade: ["tradingview"],
                  business: ["gmail", "quickbooks"] }[road] || ["gmail"];
      firstrun = "the bookkeeper reconciles sample numbers onto money watch — live, on load";
    } else if (s.intent === "productivity") {
      ws = ["desk", "inbox watch, today, paper trail"];
      agents = [["chief of staff", "triages your inbox, drafts replies, keeps today current"]];
      rules = [{ inbox: "when an email needs a reply, draft one in my voice",
                 calendar: "when two things collide on the calendar, warn me first",
                 paperwork: "when a receipt or invoice lands, file it in the paper trail",
                 scattered: "when a file lands, file it where i'd actually look",
                 people: "every morning, summarize where every project stands",
                 all: "when an email needs a reply, draft one in my voice" }[s.prod_pain] || "every morning, summarize overnight into today"];
      connect = ["gmail", "google drive"];
      firstrun = "the chief of staff triages your last 24 hours of inbox on load";
    } else if (s.intent === "delegate") {
      ws = [s.hours === "nights" ? "night shift" : "crew", "queue, morning report, fleet log"];
      agents = [{ watch: ["lookout", "watches your streams, tells you what matters"],
                  research: ["night researcher", "digs into the queue, reports by morning"],
                  produce: ["producer", "makes the scheduled things, on time, every time"],
                  grind: ["clerk", "does the recurring busywork before you notice it"] }[s.delegate_job] || ["worker", "takes the queue, top to bottom"],
                ["foreman", "watches budget and hours, kills overruns"]];
      rules = [{ watch: "when something important happens, ping me once",
                 research: "every night, take the top question and report by morning",
                 produce: "on every schedule tick, make the thing and stage it",
                 grind: "when the busywork appears, do it and keep receipts" }[s.delegate_job] || "take the top of the queue, report when done"];
      connect = ["github", "google"];
      firstrun = "the fleet takes its first job the moment the world opens";
    } else if (s.intent === "build") {
      const site = s.build_what === "site" || s.build_what === "store";
      ws = site ? ["studio", "site, design tokens, publish log"]
                : ["workshop", "builds, tests, ship log"];
      agents = site ? [["art director", "keeps everything matching your taste"]]
                    : [["builder", "turns descriptions into working builds"]];
      rules = ["when i add a page, style it to my taste and stage a preview"];
      connect = site ? ["cloudflare", "github"] : ["github"];
      firstrun = "a starter build blooms from your answers on load";
    } else {
      ws = ["notebook", "scratch, library"];
      agents = [["study buddy", "fetches, summarizes, files what you keep"]];
      rules = ["when i tag #keep, file it in the library with a summary"];
      connect = ["google"];
      firstrun = "a demo rule fires on load — plain words, running";
    }
    // aspirations top up the rules (skip duplicates), max 3 total
    const aspRule = { inbox: "when an email needs a reply, draft one in my voice",
                      paperwork: "when a receipt or invoice lands, file it in the paper trail",
                      research: "every night, research the top question in the queue",
                      publish: "every week, draft the next post in my voice",
                      ghost: "learn my voice from everything i write",
                      watch: "when a watched number moves hard, alert me once",
                      organize: "when a file lands, file it where i'd actually look",
                      website: "stage a starter site from my taste answers",
                      teamtools: "draft the internal tool nobody volunteered to build" };
    asp.forEach(a => {
      const r = aspRule[a];
      if (r && rules.length < 3 && !rules.includes(r)) rules.push(r);
    });
    // picked platforms lead the connect order
    const picked = (s.platforms || "").split(",").filter(v => v && v !== "none");
    connect = [...new Set([...picked.slice(0, 3), ...connect])].slice(0, 4);
    const lines = [];
    lines.push(["workspace", `${ws[0]} — ${ws[1]}`]);
    agents.slice(0, 2).forEach((a, i) => lines.push([`agent.${i + 1}`, `${a[0]} — ${a[1]}`]));
    rules.forEach((r, i) => lines.push([`rule.${i + 1}`, r]));
    lines.push(["connect", connect.join(", ")]);
    const setting = ["leash", "pings", "oops", "voice"].filter(k => s[k]).map(k => `${k}=${s[k]}`).join(" ");
    if (setting) lines.push(["setting", setting]);
    if (s.intent === "delegate" && (s.hours || s.burn))
      lines.push(["fleet", `hours=${s.hours || "?"} budget=${s.burn || "?"}`]);
    lines.push(["firstrun", firstrun]);
    return lines;
  }

  // labels for the recap — keys read as plain words
  const KEY_LABEL = {
    intent: "here for", blank_nudge: "nudge", build_what: "making", build_site_job: "site does",
    build_tool_who: "tool for", money_road: "road", money_sell_what: "selling",
    money_audience_medium: "medium", money_freelance_craft: "craft", money_trade_flavor: "flavor",
    money_biz_bottleneck: "bottleneck", prod_pain: "time sink", prod_scope: "for",
    delegate_job: "handed off", platforms: "platforms", industry: "industry", aspirations: "wishlist",
    speak: "code", language: "language", git: "git", gitrules: "laws", pen: "pen", fence: "fence",
    trust: "trust", research: "research", narrate: "narration", depth: "depth", firstwin: "first win",
    watch: "reads", offlimits: "off-limits", voice: "voice", leash: "leash", pings: "pings",
    oops: "breakage", hours: "hours", burn: "budget", start: "starts with", taste: "taste",
    motion: "motion", moneyrules: "money",
  };

  let state = {}, notes = {}, history = [], hooks = {}, root = null, faceApi = null;
  let notesEverOpened = false, _keysBound = false;

  const save = (k, v) =>
    hooks.post && hooks.post(`/profile/set?key=${encodeURIComponent(k)}&value=${encodeURIComponent(v)}`);
  const opts = node => (typeof node.options === "function" ? node.options(state) : node.options);

  // remaining-path estimate (walks next() on current state) → progress + minutes
  function remaining(id) {
    let n = 0;
    while (id) { n++; id = NODES[id].next(state); if (n > 30) break; }
    return n;
  }
  const minutesLeft = id => Math.max(1, Math.ceil(remaining(id) * 18 / 60));

  function media(o) {
    if (o.lot) return `<div class="qzlot" data-lot="${o.lot}"></div>`;
    if (o.mic) return `<img class="qzmic" src="/static/micons/${o.mic}.svg" alt="">`;
    if (o.gly) return `<span class="qzglyph"><i data-lucide="${o.gly}"></i></span>`;
    return "";
  }

  // ── card animations: first-frame static → loop on hover → freeze on leave →
  //    RESUME from the frozen frame on re-hover (pause/play, never a restart) ──
  let anims = [];
  function destroyAnims() { anims.forEach(a => a.destroy()); anims = []; }
  function initLotties(scope) {
    scope.querySelectorAll(".qzlot").forEach(el => {
      const anim = lottie.loadAnimation({
        container: el, renderer: "svg", loop: true, autoplay: !!el.dataset.auto,
        path: `/static/lotties/${el.dataset.lot}.json`,
      });
      anim.addEventListener("DOMLoaded", () => { if (!el.dataset.auto) anim.goToAndStop(0, true); });
      anims.push(anim);
      const card = el.closest(".qzcard");
      if (!card) return;
      card.addEventListener("mouseenter", () => anim.play());
      card.addEventListener("mouseleave", () => anim.pause());
    });
  }

  // ── notes drawer (every question): typed or dictated, saved per-question ────
  function notesUI(id) {
    return `
      <div class="qznotes" style="display:none">
        <textarea placeholder="what would you tell a sharp assistant that the buttons couldn't capture? caveats, exceptions, strong opinions. it all gets used."></textarea>
        <button class="qzdictate">dictate</button>
        <span class="qznoted">noted.</span>
      </div>`;
  }
  function bindNotes(body, id) {
    const drawer = body.querySelector(".qznotes");
    const btn = body.querySelector(".qznotebtn");
    if (!drawer || !btn) return;
    const ta = drawer.querySelector("textarea");
    const dict = drawer.querySelector(".qzdictate");
    const noted = drawer.querySelector(".qznoted");
    ta.value = notes[id] || "";
    let saveTimer = null;
    const persist = () => {
      notes[id] = ta.value;
      save(`${id}.notes`, ta.value);
      gsap.fromTo(noted, { opacity: 0 }, { opacity: 1, duration: .25 });
      gsap.to(noted, { opacity: 0, duration: .4, delay: 1.5 });
      btn.innerHTML = ta.value.trim() ? `notes<span class="qzdot"></span>` : "notes";
    };
    ta.addEventListener("input", () => { clearTimeout(saveTimer); saveTimer = setTimeout(persist, 800); });
    btn.onclick = () => {
      notesEverOpened = true;
      const open = drawer.style.display !== "none";
      drawer.style.display = open ? "none" : "flex";
      if (!open) { gsap.from(drawer, { y: 10, autoAlpha: 0, duration: .25, ease: "power2.out" }); ta.focus(); }
    };
    body._toggleNotes = () => btn.onclick();
    // dictation: MediaRecorder → /voice/dictate (moonshine, local) → append
    let rec = null, chunks = [];
    dict.onclick = async () => {
      if (rec && rec.state === "recording") { rec.stop(); return; }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        chunks = [];
        rec = new MediaRecorder(stream, { mimeType: "audio/mp4" });
        rec.ondataavailable = e => chunks.push(e.data);
        rec.onstop = async () => {
          stream.getTracks().forEach(t => t.stop());
          dict.classList.remove("rec");
          dict.textContent = "transcribing…";
          try {
            const blob = new Blob(chunks, { type: "audio/mp4" });
            const r = await hooks.postRaw("/voice/dictate", blob, "audio/mp4");
            const text = r.ok ? (await r.text()).trim() : "";
            if (text) { ta.value = (ta.value ? ta.value + " " : "") + text; persist(); }
          } finally { dict.textContent = "dictate"; }
        };
        rec.start();
        dict.classList.add("rec");
        dict.textContent = "listening — press to stop";
      } catch (_) { dict.textContent = "mic unavailable"; setTimeout(() => dict.textContent = "dictate", 1600); }
    };
  }

  // ── per-widget body builders ────────────────────────────────────────────────
  function navHTML(node, picked) {
    return `
      <div class="qznav">
        ${history.length ? `<button class="qzback" title="back"><i data-lucide="arrow-left"></i></button>` : ""}
        <button class="qznotebtn">${(notes[_current] || "").trim() ? `notes<span class="qzdot"></span>` : "notes"}</button>
        <div class="qzbar"><div class="qzbarfill"></div></div>
        ${node.multi || node.widget === "pick" ? `<button class="qzgo" ${picked.length ? "" : "disabled"}>continue</button>` : ""}
      </div>
      ${notesEverOpened || history.length > 1 ? "" : `<div class="qzhint">press n to add notes</div>`}
      ${notesUI(_current)}`;
  }

  function headHTML(node) {
    return `
      <div class="qzhead">
        <div class="qzkicker">setting up your nexus</div>
        <div class="qztitle">${node.title}</div>
        <p class="qzsub">${node.sub}</p>
      </div>`;
  }

  function buildCards(body, node, id) {
    const options = opts(node);
    const picked = (state[id] || "").split(",").filter(Boolean);
    body.innerHTML = `
      ${headHTML(node)}
      <div class="qzcards${options.length <= 5 ? " row" : ""}">${options.map((o, i) => `
        <button class="qzcard${picked.includes(o.v) ? " on" : ""}" data-i="${i}">
          <span class="qzck"><i data-lucide="check"></i></span>
          ${media(o)}
          <span class="qzname">${o.name}</span>
          <span class="qzline">${o.line || ""}</span>
        </button>`).join("")}
      </div>
      ${navHTML(node, picked)}`;
    body.querySelectorAll(".qzcard").forEach(card => card.onclick = () => {
      const o = options[+card.dataset.i];
      if (node.multi) {
        card.classList.toggle("on");
        const on = [...body.querySelectorAll(".qzcard.on")].map(c => options[+c.dataset.i].v);
        state[id] = on.join(",");
        body.querySelector(".qzgo").disabled = !on.length;
        gsap.fromTo(card, { scale: .96 }, { scale: 1, duration: .3, ease: "back.out(3)" });
        return;
      }
      body.querySelectorAll(".qzcard").forEach(c => c.classList.remove("on"));
      card.classList.add("on");
      state[id] = o.v;
      save(id, o.v);
      gsap.fromTo(card, { scale: .96 }, { scale: 1, duration: .3, ease: "back.out(3)" });
      setTimeout(() => advance(id), 300);
    });
    gsap.from(body.querySelectorAll(".qzcard"),
      { y: 10, autoAlpha: 0, duration: .35, delay: .08, stagger: .05, ease: "power2.out" });
  }

  function buildPick(body, node, id) {
    const options = opts(node);
    const picked = (state[id] || "").split(",").filter(Boolean);
    const searchable = options.length > 10;
    body.innerHTML = `
      ${headHTML(node)}
      ${searchable ? `<input class="qzsearch" placeholder="type to filter">` : ""}
      <div class="qzchipgrid">
        ${options.map((o, i) => `<button class="qzchip2${picked.includes(o.v) ? " on" : ""}" data-i="${i}" data-v="${o.v}">${o.name}</button>`).join("")}
        <button class="qzchip2 none${picked.includes("none") ? " on" : ""}" data-v="none">none of these</button>
      </div>
      <div class="qzchipline"></div>
      ${navHTML(node, picked)}`;
    const grid = body.querySelector(".qzchipgrid");
    const lineEl = body.querySelector(".qzchipline");
    const sync = () => {
      const on = [...grid.querySelectorAll(".qzchip2.on")].map(c => c.dataset.v);
      state[id] = on.join(",");
      body.querySelector(".qzgo").disabled = !on.length;
      const go = body.querySelector(".qzgo");
      go.textContent = on.length && !on.includes("none") ? `continue (${on.length})` : "continue";
      lineEl.textContent = on.length >= 6 ? "six is a lot. we'll keep up." : "";
    };
    grid.querySelectorAll(".qzchip2").forEach(chip => chip.onclick = () => {
      const isNone = chip.dataset.v === "none";
      if (isNone) grid.querySelectorAll(".qzchip2.on").forEach(c => c.classList.remove("on"));
      else grid.querySelector(".qzchip2.none")?.classList.remove("on");
      chip.classList.toggle("on");
      gsap.fromTo(chip, { scale: .95 }, { scale: 1, duration: .25, ease: "back.out(3)" });
      sync();
    });
    const search = body.querySelector(".qzsearch");
    if (search) search.addEventListener("input", () => {
      const q = search.value.trim().toLowerCase();
      grid.querySelectorAll(".qzchip2").forEach(c => {
        const keep = c.classList.contains("on") || c.classList.contains("none") ||
          c.textContent.toLowerCase().includes(q);
        c.style.display = keep ? "" : "none";
      });
    });
    sync();
    gsap.from(grid.querySelectorAll(".qzchip2"),
      { y: 8, autoAlpha: 0, duration: .3, delay: .06, stagger: .025, ease: "power2.out" });
  }

  function buildSearch(body, node, id) {
    const options = opts(node);
    body.innerHTML = `
      ${headHTML(node)}
      <input class="qzsearch" placeholder="start typing your industry">
      <div class="qzrows"></div>
      ${navHTML(node, [])}`;
    const input = body.querySelector(".qzsearch");
    const rows = body.querySelector(".qzrows");
    const pickRow = (v, label) => {
      state[id] = v;
      save(id, v === label ? v : `${v} (${label})`);
      advance(id);
    };
    const renderRows = () => {
      const q = input.value.trim().toLowerCase();
      const hits = options.filter(o => o.name.toLowerCase().includes(q) || o.v.includes(q));
      const shown = q ? hits : options.slice(0, 8);
      rows.innerHTML = shown.map(o => `<button class="qzrow" data-v="${o.v}">${o.name}</button>`).join("") +
        (q && !hits.length ? `<button class="qzrow custom">use "${input.value.trim()}" →</button>` : "");
      rows.querySelectorAll(".qzrow").forEach(r => r.onclick = () => {
        if (r.classList.contains("custom")) return pickRow(input.value.trim(), input.value.trim());
        pickRow(r.dataset.v, r.textContent);
      });
    };
    input.addEventListener("input", renderRows);
    input.addEventListener("keydown", e => {
      if (e.key === "Enter") rows.querySelector(".qzrow")?.click();
    });
    renderRows();
    setTimeout(() => input.focus(), 350);
  }

  function buildChapter(body, node, id) {
    body.innerHTML = `
      <div class="qzhead" style="cursor:pointer">
        <div class="qzkicker">${node.part}</div>
        <div class="qztitle">${node.title}</div>
        <p class="qzsub">${node.line}</p>
        <div class="qzmeta">about ${minutesLeft(node.next(state))} minute${minutesLeft(node.next(state)) === 1 ? "" : "s"} left</div>
      </div>`;
    if (faceApi) faceApi.setMouth("happy");
    let advanced = false;
    const go = () => { if (!advanced) { advanced = true; advance(id); } };
    body.querySelector(".qzhead").onclick = go;
    setTimeout(go, 2400);
  }

  function buildIntro(body, node, id) {
    body.innerHTML = `
      <div class="qzhead">
        <div class="qzkicker">setup</div>
        <div class="qztitle">got ten minutes?</div>
        <p class="qzsub">every question here builds something for you. the more you answer, the more gets built. we don't ask anything we don't use.</p>
        <div class="qzmeta">~16 questions · 5–10 min · notes optional</div>
      </div>
      <div class="qznav"><button class="qzgo" id="qzstart">start →</button></div>
      <button class="qzlater" id="qzlater">later →</button>`;
    body.querySelector("#qzstart").onclick = () => advance(id);
    body.querySelector("#qzlater").onclick = () => hooks.onDone && hooks.onDone();
  }

  let _current = null;
  function render(id, dir) {
    _current = id;
    const node = NODES[id];
    const body = root.querySelector(".qzbody");
    const build = () => {
      destroyAnims();
      const widget = node.widget || "cards";
      if (widget === "intro") buildIntro(body, node, id);
      else if (widget === "chapter") buildChapter(body, node, id);
      else if (widget === "pick") buildPick(body, node, id);
      else if (widget === "search") buildSearch(body, node, id);
      else buildCards(body, node, id);
      (hooks.refreshIcons || (() => {}))();
      initLotties(body);
      if (widget !== "intro" && widget !== "chapter") {
        const done = history.length + 1;
        gsap.to(body.querySelector(".qzbarfill"),
          { width: `${Math.round(100 * done / (done + remaining(node.next(state))))}%`, duration: .5, ease: "power2.out" });
        const back = body.querySelector(".qzback");
        if (back) back.onclick = () => { const prev = history.pop(); render(prev, -1); };
        const go = body.querySelector(".qzgo");
        if (go && (node.multi || widget === "pick"))
          go.onclick = () => { save(id, state[id] || ""); advance(id); };
        bindNotes(body, id);
      }
      gsap.fromTo(body, { x: 26 * dir, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: .4, ease: "power2.out" });
    };
    gsap.to(body, { x: -26 * dir, autoAlpha: 0, duration: .2, ease: "power1.in", onComplete: build });
    if (faceApi && node.widget !== "chapter") faceApi.setMouth(node.mood || "neutral");
  }

  function advance(id) {
    const nxt = NODES[id].next(state);
    history.push(id);
    if (nxt) return render(nxt, 1);
    finale();
  }

  function finale() {
    _current = null;
    if (faceApi) faceApi.setMouth("superHappy");
    const body = root.querySelector(".qzbody");
    const plan = planFor(state);
    plan.forEach(([k, v]) => save(`plan.${k}`, v));
    const build = () => {
      destroyAnims();
      body.innerHTML = `
        <div class="qzhead">
          <div class="qzkicker">setting up your nexus</div>
          <div class="qztitle">your starting world</div>
          <p class="qzsub">built from your answers. it starts running the moment you enter — and it's all just text you can change.</p>
        </div>
        <div class="qzlot" data-lot="tournament-victory" data-auto="1" style="width:96px;height:96px"></div>
        <div class="qzplan">
          ${plan.map(([k, v]) => `<div class="qzplanrow${k === "firstrun" ? " run" : ""}"><b>${k.replace(/\.\d+$/, "")}</b><span>${v}</span></div>`).join("")}
        </div>
        <div class="qznav"><button class="qzgo" id="qzenter">enter autopoet — watch it run</button></div>`;
      body.querySelector("#qzenter").onclick = () => hooks.onDone && hooks.onDone();
      initLotties(body);
      gsap.fromTo(body, { x: 26, autoAlpha: 0 }, { x: 0, autoAlpha: 1, duration: .4, ease: "power2.out" });
      gsap.from(body.querySelectorAll(".qzplanrow"),
        { y: 8, autoAlpha: 0, duration: .3, delay: .15, stagger: .07, ease: "power2.out" });
    };
    gsap.to(body, { x: -26, autoAlpha: 0, duration: .2, ease: "power1.in", onComplete: build });
  }

  function start(container, h) {
    hooks = h || {};
    state = {}; notes = {}; history = [];
    root = container;
    destroyAnims();
    if (!document.getElementById("qzcss")) {
      const st = document.createElement("style");
      st.id = "qzcss"; st.textContent = CSS;
      document.head.appendChild(st);
    }
    container.innerHTML = `
      <div class="qzface"></div>
      <div class="qzbody" style="display:flex;flex-direction:column;align-items:center;gap:18px;width:100%"></div>`;
    if (hooks.createFace)
      hooks.createFace(container.querySelector(".qzface"), { idPrefix: "qz" }).then(api => { faceApi = api; });
    if (!_keysBound) {
      _keysBound = true;
      addEventListener("keydown", e => {
        if (!root || root.style.display === "none" || e.key !== "n") return;
        const t = e.target;
        if (t && (t.tagName === "TEXTAREA" || t.tagName === "INPUT")) return;
        const body = root.querySelector(".qzbody");
        if (body && body._toggleNotes) { e.preventDefault(); body._toggleNotes(); }
      });
    }
    render(START, 1);
  }

  window.AutopoetQuiz = { start, _anims: () => anims, _state: () => state };
})();
