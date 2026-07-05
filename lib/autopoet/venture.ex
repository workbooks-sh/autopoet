defmodule Autopoet.Venture do
  @moduledoc """
  The VENTURE DESK — a second always-on autopoet that builds and markets its
  own SaaS AI product for marketers in a niche it discovers itself (wb-siutv,
  the autonomous business loop). Same constitution discipline as the fund desk:

    GENESIS (no charter = no venture): three 15-min research slots — (1) mine
    REAL practitioner pain from the live web (nexus browser: communities,
    forums, X public pages) in marketing niches; (2) pick ONE niche + product
    thesis, validated against that feedback; (3) write the founding charter
    (Mission/Niche+ICP/Product/Validation/GTM/Metrics+Kill) → PENDING PROPOSAL
    to the human agent. Nothing ships until acceptance.

    CHARTERED LOOP (each on its own cadence, one unit per 15-min slot):
      * build    — write/iterate the product's landing page + copy in the body
                   (venture/site/), then DEPLOY REAL to Cloudflare Pages
                   (wrangler, logged in) — a live URL, not a mock.
      * feedback — mine fresh practitioner feedback on the niche/product from
                   the live web; when an X token is connected, mentions+replies
                   join the feed.
      * market   — draft X posts / content; OUTWARD actions are GATED: drafts
                   land as proposals for the human agent; posting requires the
                   X connection + acceptance. Paid ads additionally ride
                   Autopoet.Treasury (cap $0 until a human funds it — cannot
                   spend a cent).
      * measure  — site traffic/waitlist → Autopoet.Market.ingest → the reward
                   ledger. The market stays the judge.

  Rails all hard: no paid spend without Treasury allowance, outward posts
  gated, LLM budget/day, every exception → issues.log; heartbeat + uptime in
  the artifacts dir (AUTOPOET_DESK_DIR, default eval/venture). Enabled only
  when AUTOPOET_VENTURE=1.
  """
  use GenServer
  require Logger

  @tick 60_000
  @slot_every 900
  @max_llm_day 150
  @agenda ~w(build feedback market measure)a

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(nil) do
    File.mkdir_p!(artifacts())

    state =
      case Autopoet.Shadow.load("venture") do
        {:ok, s} -> Map.merge(defaults(), s)
        :none -> defaults()
      end

    Process.send_after(self(), :tick, 5_000)
    log("venture desk up — genesis #{if charter?(), do: "done (chartered)", else: "pending"}")
    {:ok, state}
  end

  defp defaults do
    %{
      day: nil,
      llm_calls: 0,
      last_slot: 0,
      genesis_step: 0,
      genesis_proposed: false,
      identity_proposed: false,
      agenda_idx: 0,
      work_cycles: 0,
      deploys: 0,
      site_url: nil,
      last_signups: 0,
      cycles: 0
    }
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, Map.take(s, [:day, :llm_calls, :work_cycles, :genesis_step, :deploys, :site_url, :agenda_idx, :cycles]), s}

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick)

    s =
      try do
        s |> roll_day() |> heartbeat() |> step()
      rescue
        e -> issue("tick crashed: #{Exception.message(e)} #{inspect(Enum.take(__STACKTRACE__, 3))}") && s
      catch
        kind, reason -> issue("tick threw: #{inspect(kind)} #{inspect(reason)}") && s
      end

    Autopoet.Shadow.save("venture", s)
    {:noreply, %{s | cycles: s.cycles + 1}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── cadence: one unit of work per 15-min slot ───────────────────────────────

  defp step(s) do
    if System.os_time(:second) - s.last_slot >= @slot_every do
      s = %{s | last_slot: System.os_time(:second)}

      cond do
        not charter?() -> genesis_step(s)
        # IDENTITY: one slot, once — the venture claims its own domain, email
        # proxies, and X presence (a PROPOSAL; the human agent executes the
        # DNS/routing on acceptance). Runs before the first build. OWNER
        # FEEDBACK (identity-feedback.txt) retracts + re-opens the slot.
        not identity?() and (not s.identity_proposed or identity_feedback() != "") -> identity_step(s)
        # LOGO: one slot, once identity is ratified — the venture designs its
        # own mark (svg-logo-designer discipline), before the first real build
        identity?() and not logo?() -> logo_step(s)
        true -> venture_cycle(s)
      end
    else
      s
    end
  end

  defp identity_step(s) do
    log("IDENTITY — claiming domain + email + X presence (proposal)")
    feedback = identity_feedback()

    with {:ok, s, reply} <- think(s, :identity, identity_prompt(feedback), max_tokens: 1800) do
      # consume the feedback so the slot doesn't loop
      if feedback != "", do: File.rm(Path.join(artifacts(), "identity-feedback.txt"))
      id =
        Autopoet.Proposals.record(
          %{target: "venture/identity.work", kind: "venture.identity", source: "venture-identity"},
          %{"venture/identity.work" => reply}
        )

      File.write!(Path.join(artifacts(), "proposals.log"), "#{DateTime.to_iso8601(DateTime.utc_now())} | #{id} | venture.identity | domain+email+x\n", [:append])
      log("IDENTITY PROPOSED (#{id})")
      %{s | identity_proposed: true, work_cycles: s.work_cycles + 1}
    end
  end

  # identity is REAL once the accepted identity doc exists (vault-first, like
  # the charter — the human-executed copy)
  defp identity? do
    vault = Path.join(Autopoet.Notes.dir(), "venture/identity.work")
    File.exists?(vault) or not String.starts_with?(read_body("venture/identity.work"), "(no")
  rescue
    _ -> false
  end

  # ── LOGO: the venture designs its own mark ──────────────────────────────────

  defp logo?, do: not String.starts_with?(read_body("venture/logo.work"), "(no")

  defp logo_step(s) do
    log("LOGO — designing the mark (3 concepts, self-judged)")

    with {:ok, s, reply} <- think(s, :logo, logo_prompt(), max_tokens: 3500) do
      svgs = Regex.scan(~r/===\s*svg:\s*([a-z0-9-]+)\s*===\s*\n(.*?)(?=\n===|\z)/s, reply)

      if svgs == [] do
        issue("logo slot produced no svg blocks")
        s
      else
        dir = Path.join(artifacts(), "site/assets")
        File.mkdir_p!(dir)

        for [_, name, svg] <- svgs do
          File.write!(Path.join(dir, "#{name}.svg"), String.trim(svg))
        end

        append_body("venture/logo.work", "# The mark\n\n" <> strip_svgs(reply) <> "\n\nAssets: " <> Enum.map_join(svgs, ", ", fn [_, n, _] -> "#{n}.svg" end))
        log("LOGO — #{length(svgs)} assets written")
        %{s | work_cycles: s.work_cycles + 1}
      end
    end
  end

  defp strip_svgs(reply), do: Regex.replace(~r/===\s*svg:.*?(?=\n===|\z)/s, reply, "")

  defp logo_assets do
    case File.ls(Path.join(artifacts(), "site/assets")) do
      {:ok, fs} -> Enum.join(fs, ", ")
      _ -> "(none yet)"
    end
  rescue
    _ -> "(none yet)"
  end

  defp logo_prompt do
    """
    You are the founder of the venture whose identity you ratified below — design YOUR OWN LOGO.
    #{identity_doc()}
    Charter mission: #{charter_section("Mission")}

    Discipline (non-negotiable): great logos are simple, memorable, timeless,
    versatile, appropriate. Every SVG: a responsive viewBox (no pixel sizes),
    colors defined ONCE in <defs> and reused, semantic <g> groups, role="img" +
    <title> + <desc> for accessibility, minimal paths, no invisible elements,
    legible at 16px and at billboard scale.

    Produce THREE distinct concepts (different visual mechanisms, not variants
    of one idea). For each, write one line of rationale, then the icon-only
    mark. Then judge them honestly against the discipline and PICK ONE primary.
    Emit blocks exactly like:

    === svg: concept1-icon ===
    <svg …>…</svg>

    === svg: concept2-icon ===
    <svg …>…</svg>

    === svg: concept3-icon ===
    <svg …>…</svg>

    === svg: primary-mono ===
    <the chosen concept re-cut in single-color monochrome>

    End with: PRIMARY: <concept name> and the rationale for the choice.
    """
  end

  defp identity_doc do
    vault = Path.join(Autopoet.Notes.dir(), "venture/identity.work")

    case File.read(vault) do
      {:ok, c} -> String.slice(c, 0, 2500)
      _ -> read_body("venture/identity.work")
    end
  rescue
    _ -> read_body("venture/identity.work")
  end

  # the venture's PUBLIC url — from the ratified identity (## Site), never the
  # raw pages.dev deployment url (which leaked into outbound copy as a brand)
  defp canonical_site do
    case Regex.run(~r/https:\/\/[a-z0-9.-]+/, charter_section_of(identity_doc(), "Site")) do
      [u] -> u
      _ -> "(site not yet public)"
    end
  end

  defp charter_section_of(doc, name) do
    case Regex.run(~r/##\s*#{Regex.escape(name)}[^\n]*\n(.*?)(?:\n##|\z)/s, doc) do
      [_, body] -> String.trim(body)
      _ -> ""
    end
  end

  defp identity_feedback do
    case File.read(Path.join(artifacts(), "identity-feedback.txt")) do
      {:ok, t} -> t
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp identity_prompt(feedback \\ "") do
    zones =
      case File.read(Path.join(artifacts(), "zones.txt")) do
        {:ok, t} -> t
        _ -> "(no zone inventory — propose a purchase, minimal budget ~$15)"
      end

    feedback_block = if feedback == "", do: "", else: "\nYOUR PREVIOUS PROPOSAL WAS RETRACTED. #{feedback}\n"

    """
    You are the founder of the venture chartered below. Your charter:
    #{charter()}
    #{feedback_block}
    Claim your venture's IDENTITY. Available infrastructure:
    #{zones}

    Propose, as a document the human will execute verbatim:
    ## Domain
    (ONE choice: an available zone or subdomain of one — say exactly which and
    why it fits the brand; a new purchase only if the fit is truly poor)
    ## Email
    (2-3 proxy addresses on that domain — e.g. hello@, founders@ — and what
    each is for; mail routes via Cloudflare Email Routing + a Google Workspace
    alias for sending)
    ## X presence
    (the @zaiusai rebrand: display name, 160-char bio, avatar concept, the
    pinned post text — ready to apply)
    ## Site
    (the final URL where the landing page should live on that domain)
    """
  end

  # ── GENESIS: find the niche from REAL feedback, then charter ────────────────

  defp genesis_step(%{genesis_step: 0} = s) do
    log("GENESIS 1/3 — mining real marketer pain (nexus browser)")

    with {:ok, s, harvest} <- web_research(s, "marketing practitioners complaining about tools/workflows right now: agency ops, SEO content, social scheduling, reporting, ecommerce email — real complaints from communities and forums 2026"),
         {:ok, s, reply} <- think(s, :genesis, genesis_pain_prompt(harvest), max_tokens: 2000) do
      append_body("venture/genesis-notes.work", "# Venture genesis\n\n## 1 · Real pain mined (web) #{s.day}\n\n" <> reply)
      %{s | genesis_step: 1, work_cycles: s.work_cycles + 1}
    end
  end

  defp genesis_step(%{genesis_step: 1} = s) do
    log("GENESIS 2/3 — niche + product thesis (nexus browser)")

    with {:ok, s, harvest} <- web_research(s, "existing tools, pricing, and gaps for the pains in my notes:\n#{String.slice(read_body("venture/genesis-notes.work"), 0, 1200)}"),
         {:ok, s, reply} <- think(s, :genesis, genesis_thesis_prompt(harvest), max_tokens: 2000) do
      append_body("venture/genesis-notes.work", "\n## 2 · Niche + thesis (web-validated) #{s.day}\n\n" <> reply)
      %{s | genesis_step: 2, work_cycles: s.work_cycles + 1}
    end
  end

  defp genesis_step(%{genesis_step: 2, genesis_proposed: false} = s) do
    log("GENESIS 3/3 — charter → PROPOSAL to the human agent")

    with {:ok, s, reply} <- think(s, :genesis, genesis_charter_prompt(), max_tokens: 2200) do
      draft = reply

      id =
        Autopoet.Proposals.record(
          %{target: "venture/charter.work", kind: "venture.charter", source: "venture-genesis"},
          %{"venture/charter.work" => draft}
        )

      File.write!(Path.join(artifacts(), "proposals.log"), "#{DateTime.to_iso8601(DateTime.utc_now())} | #{id} | venture.charter | venture/charter.work\n", [:append])
      log("VENTURE CHARTER PROPOSED (#{id}) — nothing ships until acceptance")
      %{s | genesis_proposed: true, work_cycles: s.work_cycles + 1}
    end
  end

  defp genesis_step(s), do: s

  # ── the chartered loop ──────────────────────────────────────────────────────

  defp venture_cycle(s) do
    task = Enum.at(@agenda, rem(s.agenda_idx, length(@agenda)))
    s = %{s | agenda_idx: s.agenda_idx + 1}
    log("venture cycle: #{task} (#{s.work_cycles + 1})")

    case task do
      :build -> build_cycle(s)
      :feedback -> feedback_cycle(s)
      :market -> market_cycle(s)
      :measure -> measure_cycle(s)
    end
  end

  # BUILD: author/iterate the landing page, deploy REAL to Cloudflare Pages
  defp build_cycle(s) do
    with {:ok, s, reply} <- think(s, :build, build_prompt(s), max_tokens: 3000) do
      html = extract_html(reply)

      if html == "" do
        issue("build cycle produced no html block")
        %{s | work_cycles: s.work_cycles + 1}
      else
        site_dir = Path.join(artifacts(), "site")
        File.mkdir_p!(site_dir)
        File.write!(Path.join(site_dir, "index.html"), html)
        append_body("venture/build-log.work", "\n## build #{s.day} ##{s.work_cycles + 1}\n\n#{String.slice(reply, 0, 400)}\n")

        case deploy(site_dir) do
          {:ok, url} ->
            log("DEPLOYED → #{url}")
            %{s | work_cycles: s.work_cycles + 1, deploys: s.deploys + 1, site_url: url}

          {:error, why} ->
            issue("deploy failed: #{String.slice(why, 0, 200)}")
            %{s | work_cycles: s.work_cycles + 1}
        end
      end
    end
  end

  # FEEDBACK: real practitioner reactions from the live web (+X when connected)
  defp feedback_cycle(s) do
    with {:ok, s, harvest} <- web_research(s, "reactions, complaints, and feature demands about: #{String.slice(charter_section("Niche"), 0, 300)} — real posts from practitioners"),
         {:ok, s, reply} <- think(s, :feedback, feedback_prompt(harvest <> x_harvest(s) <> inbox_harvest()), max_tokens: 1600) do
      append_body("venture/feedback.work", "\n## feedback #{s.day} ##{s.work_cycles + 1}\n\n" <> reply)
      %{s | work_cycles: s.work_cycles + 1}
    end
  end

  # the venture's OWN inbox (citeflows@agentmail.to): inbound replies are real
  # qualitative feedback — validation metric #2. Skips cleanly if unconfigured.
  defp inbox_harvest do
    case Autopoet.AgentMail.messages("citeflows@agentmail.to") do
      {:ok, %{"messages" => msgs}} when is_list(msgs) and msgs != [] ->
        "\n\n--- YOUR INBOX (citeflows@agentmail.to) ---\n" <>
          Enum.map_join(Enum.take(msgs, 8), "\n", fn m ->
            "FROM #{m["from"] || "?"}: #{String.slice(m["subject"] || "", 0, 80)} — #{String.slice(m["preview"] || m["text"] || "", 0, 160)}"
          end)

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  # X recent-search: live practitioner posts on the niche. Skips cleanly when
  # unconnected or the dev account has no API credits (X's credit pricing).
  defp x_harvest(_s) do
    case x_token() do
      nil ->
        ""

      bearer ->
        q = URI.encode_www_form(String.slice(charter_section("Niche"), 0, 60) <> " -is:retweet lang:en")
        url = "https://api.twitter.com/2/tweets/search/recent?query=#{q}&max_results=10"

        :inets.start()
        :ssl.start()

        case :httpc.request(:get, {String.to_charlist(url), [{~c"authorization", String.to_charlist("Bearer " <> bearer)}]}, [timeout: 15_000], body_format: :binary) do
          {:ok, {{_, 200, _}, _, body}} ->
            case Jason.decode(body) do
              {:ok, %{"data" => tweets}} ->
                "\n\n--- LIVE X POSTS ---\n" <> Enum.map_join(tweets, "\n", fn t -> "X: " <> String.slice(t["text"] || "", 0, 240) end)

              _ ->
                ""
            end

          {:ok, {{_, code, _}, _, body}} ->
            # known-degraded lane (e.g. CreditsDepleted): log once per day, not
            # every slot — repeats drown real issues
            marker = Path.join(artifacts(), "x-issue-day.txt")
            today = Date.to_iso8601(Date.utc_today())

            if File.read(marker) != {:ok, today} do
              File.write!(marker, today)
              issue("x search #{code}: #{String.slice(to_string(body), 0, 120)} (throttled to 1/day)")
            end

            ""

          _ ->
            ""
        end
    end
  rescue
    _ -> ""
  end

  # MARKET: draft outward content — GATED: drafts are proposals, posting needs
  # the X connection + human acceptance; paid ads additionally Treasury-gated
  defp market_cycle(s) do
    with {:ok, s, reply} <- think(s, :market, market_prompt(s), max_tokens: 1600) do
      id =
        Autopoet.Proposals.record(
          %{target: "venture/posts.work", kind: "venture.posts", source: "venture-market"},
          %{"venture/posts-#{s.day}-#{s.work_cycles}.work" => reply}
        )

      File.write!(Path.join(artifacts(), "proposals.log"), "#{DateTime.to_iso8601(DateTime.utc_now())} | #{id} | venture.posts | drafts\n", [:append])
      log("post drafts → proposal #{id} (outward = gated)")
      %{s | work_cycles: s.work_cycles + 1}
    end
  end

  # MEASURE: the market judges — site signals → reward ledger
  defp measure_cycle(s) do
    signals = site_signals(s)
    s = %{s | last_signups: Process.get(:venture_signup_count, Map.get(s, :last_signups, 0))}

    if signals != [] do
      Autopoet.Market.ingest(signals)
      log("measured: #{inspect(Enum.map(signals, & &1.kind))}")
    end

    with {:ok, s, reply} <- think(s, :measure, measure_prompt(s, signals), max_tokens: 1200) do
      append_body("venture/journal.work", "\n## measure #{s.day} ##{s.work_cycles + 1}\n\n" <> reply)
      %{s | work_cycles: s.work_cycles + 1}
    end
  end

  # ── real lanes ──────────────────────────────────────────────────────────────

  # Cloudflare Pages via wrangler (logged in on this machine) — a REAL deploy.
  defp deploy(site_dir) do
    project = "autopoet-venture"

    # pin the account: the OAuth login sees multiple CF accounts and wrangler
    # refuses to guess (issues.log #1-5); the venture lives on the owner's
    env = [{"CLOUDFLARE_ACCOUNT_ID", System.get_env("CF_ACCOUNT_ID") || "6d4b74aeb10f455fbf88141901e7595d"}]

    case System.cmd("wrangler", ["pages", "deploy", site_dir, "--project-name=#{project}", "--branch=main", "--commit-dirty=true"], stderr_to_stdout: true, env: env) do
      {out, 0} ->
        url =
          case Regex.run(~r/https:\/\/[a-z0-9.-]+\.pages\.dev/, out) do
            [u] -> u
            _ -> "https://#{project}.pages.dev"
          end

        {:ok, url}

      {out, _} ->
        {:error, out}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # X lane: live when a bearer token is connected; skip cleanly otherwise.
  defp x_token do
    Nexus.Secrets.get("X_BEARER_TOKEN")
  rescue
    _ -> nil
  end

  # REAL site signals: the live waitlist count (citeflows.com/api/waitlist/count,
  # KV-backed). Delta since last measure → signup signals for the reward ledger.
  defp site_signals(s) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {~c"https://citeflows.com/api/waitlist/count", []}, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        count = case Integer.parse(String.trim(to_string(body))) do
          {n, _} -> n
          _ -> 0
        end

        prev = Map.get(s, :last_signups, 0)
        delta = count - prev
        Process.put(:venture_signup_count, count)
        if delta > 0, do: [%{kind: :signup, target: "citeflows", value: delta}], else: []

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # ── the charter ─────────────────────────────────────────────────────────────

  defp charter do
    vault = Path.join(Autopoet.Notes.dir(), "venture/charter.work")

    case File.read(vault) do
      {:ok, c} -> String.slice(c, 0, 6000)
      _ -> read_body("venture/charter.work")
    end
  rescue
    _ -> read_body("venture/charter.work")
  end

  defp charter?, do: not String.starts_with?(charter(), "(no")

  defp charter_section(name) do
    case Regex.run(~r/##\s*#{Regex.escape(name)}[^\n]*\n(.*?)(?:\n##|\z)/s, charter()) do
      [_, body] -> String.trim(body)
      _ -> "(charter section #{name} missing)"
    end
  end

  # ── prompts ─────────────────────────────────────────────────────────────────

  defp onboarding do
    case File.read(Path.join(artifacts(), "onboarding.txt")) do
      {:ok, t} -> t
      _ -> "Build a SaaS AI product for marketers in a niche you discover from real feedback. Market it honestly. Prove demand before polish."
    end
  end

  defp genesis_pain_prompt(harvest) do
    """
    You are an autonomous product agent BOOTSTRAPPING YOUR OWN SaaS VENTURE from
    zero. Your human's onboarding note:
    #{onboarding()}

    Your capabilities: an LLM cycle every 15min 24/7; a web browser (below);
    Cloudflare Pages deploys (a real URL); X/Google marketing lanes (posting is
    human-gated; paid ads locked at $0 until funded). Target customer: MARKETERS.

    WEB RESEARCH YOU JUST GATHERED (real posts):
    #{harvest}

    From THIS evidence: extract the 5 sharpest recurring PAINS marketers voice,
    each with: who exactly feels it, the quote/evidence, what they do today,
    and why existing tools fail them. Rank by (frequency × willingness-to-pay
    signals). Cite sources.
    """
  end

  defp genesis_thesis_prompt(harvest) do
    """
    You are bootstrapping your own SaaS venture. Your pain research:
    #{read_body("venture/genesis-notes.work")}

    FRESH WEB EVIDENCE on competitors/gaps:
    #{harvest}

    COMMIT: pick ONE niche + ONE product thesis. Define:
    1. The niche + exact ICP (who, where they hang out, budget).
    2. The product: an AI SaaS you can demo via a landing page + waitlist NOW,
       and actually build incrementally. One killer workflow, not a suite.
    3. Competitive wedge (why the incumbents' users would switch — from evidence).
    4. Falsifiable demand test: what waitlist/engagement numbers within 14 days
       VALIDATE, and what numbers KILL it.
    """
  end

  defp genesis_charter_prompt do
    """
    You are bootstrapping your own SaaS venture. Your genesis research:
    #{read_body("venture/genesis-notes.work")}

    Write your FOUNDING CHARTER — the human accepts or rejects it verbatim.
    Rails regardless: paid ads locked at $0 (Treasury) until a human funds it;
    outward posts human-gated; ship via Cloudflare Pages; 15-min work slots.

    REQUIRED sections, exactly these headers:
    ## Mission
    ## Niche
    (the ICP, precisely)
    ## Product
    (the ONE workflow, the demo, the roadmap in 3 steps)
    ## Validation
    (the falsifiable 14-day demand test, NUMERIC)
    ## GTM
    (channels: X/content/communities; cadence; voice)
    ## Metrics
    (what you track weekly)
    ## Kill criteria
    (NUMERIC thresholds that mean stop)

    No commentary outside the document. This is YOUR venture — commit.
    """
  end

  defp build_prompt(s) do
    """
    You are the founder of your venture, in a building session. Your charter:
    #{charter()}
    Current deployed site: #{s.site_url || "(none yet)"}
    Latest feedback:
    #{String.slice(read_body("venture/feedback.work"), 0, 1500)}

    Your logo assets deploy alongside the page at /assets/ (#{logo_assets()}) —
    reference the primary as /assets/primary-icon.svg or inline the chosen mark.
    Brand doc: #{String.slice(read_body("venture/logo.work"), 0, 600)}

    STANDING NOTES from your human reviewer (binding for site copy too):
    #{marketing_notes()}

    HARD REQUIREMENTS for every page you ship:
    - FULLY self-contained: ALL CSS inline in <style>. NO CDN scripts (a blocked
      CDN renders your page as bare inputs — it happened). System font stack.
    - PRACTICE YOUR OWN PREACHING (you sell GEO): JSON-LD (Organization +
      SoftwareApplication) in <script type="application/ld+json">, semantic
      HTML5 sections, meta description + OpenGraph tags, honest claims only —
      every statistic attributed or framed as hypothesis, ON THE PAGE TOO.
    - The waitlist form MUST be: <form action="/api/waitlist" method="POST">
      with an email input — this endpoint is LIVE and counts toward your
      validation test. Do not alter its action.
    - Never emit or reference files other than index.html — /assets/*.svg (your
      logo) and _worker.js (infrastructure) already exist; reference the logo,
      never regenerate infra.

    Produce the COMPLETE landing page (or a sharp iteration folding in
    feedback), honest copy that speaks the ICP's language. Emit ONE block:

    === html ===
    <the complete html>
    """
  end

  defp feedback_prompt(harvest) do
    """
    You are the founder of your venture, reviewing fresh feedback. Your charter niche:
    #{charter_section("Niche")}

    FRESH WEB EVIDENCE:
    #{harvest}

    Synthesize: what practitioners are saying that CONFIRMS or THREATENS your
    thesis; feature demands worth folding into the landing page; objections
    your copy must answer. Concrete quotes, then 3 actionable changes.
    """
  end

  defp market_prompt(_s) do
    """
    You are the founder of your venture, writing this session's outbound content.
    YOUR PRODUCT (name it EXACTLY this, never a url slug or an internal label):
    #{String.slice(charter_section("Product"), 0, 300)}
    Your public site (the ONLY url you share): #{canonical_site()}
    Charter GTM:
    #{charter_section("GTM")}

    STANDING NOTES from your human reviewer (past rejections — binding):
    #{marketing_notes()}

    HONESTY RULE: never invent statistics or outcomes. Cite only numbers you
    can source from your research notes, or frame them explicitly as hypotheses
    ("we suspect", "in our early testing"). Unverifiable promises kill trust
    with this ICP.

    Draft this session's outbound: 3 X posts (each standalone, practitioner voice,
    no hype-slop, one insight each; max 260 chars each) + 1 community post
    (300 words, gives real value first, product mentioned once at the end).
    These go to the HUMAN for approval before posting — write them ready-to-ship.
    """
  end

  defp marketing_notes do
    case File.read(Path.join(artifacts(), "marketing-notes.txt")) do
      {:ok, t} -> t
      _ -> "(none yet)"
    end
  rescue
    _ -> "(none yet)"
  end

  defp measure_prompt(s, signals) do
    """
    You are the founder of your venture, measuring against your validation test. Charter validation test:
    #{charter_section("Validation")}
    Site: #{canonical_site()} · deploys so far: #{s.deploys}
    Signals this slot: #{if signals == [], do: "NONE (analytics not wired yet — say what you'd instrument first)", else: inspect(signals)}

    Journal honestly against the validation numbers: where demand proof stands,
    what's blocking measurement, the single highest-value next measurement step.
    """
  end

  # ── shared plumbing (mirrors the fund desk) ─────────────────────────────────

  defp think(s, phase, prompt, opts \\ []) do
    cond do
      not Application.get_env(:autopoet, :brain_live, true) ->
        s

      s.llm_calls >= @max_llm_day ->
        issue("llm budget exhausted in #{phase}")
        s

      true ->
        llm_opts = [max_tokens: Keyword.get(opts, :max_tokens, 1200), temperature: 0.4]

        result =
          try do
            Autopoet.Providers.openrouter([%{role: "user", content: prompt}], llm_opts)
          rescue
            e -> {:error, {:raised, Exception.message(e)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case result do
          {:ok, %{content: reply}} when is_binary(reply) -> {:ok, %{s | llm_calls: s.llm_calls + 1}, reply}
          other ->
            issue("llm failed in #{phase}: #{inspect(other) |> String.slice(0, 200)}")
            %{s | llm_calls: s.llm_calls + 1}
        end
    end
  end

  defp web_research(s, question) do
    with {:ok, s, qreply} <- think(s, :queries, "You need CURRENT web information for: #{question}\n\nReply with ONLY 3 focused search queries, one per line, nothing else.") do
      queries = qreply |> String.split("\n") |> Enum.map(&String.trim(&1, " -\"")) |> Enum.reject(&(&1 == "")) |> Enum.take(3)

      harvest =
        Enum.flat_map(queries, fn q ->
          case Nexus.Browse.search(q, limit: 3) do
            {:ok, results} ->
              results
              |> Enum.take(2)
              |> Enum.map(fn r ->
                url = str(r["url"] || r[:url]) |> URI.encode()

                body =
                  case url != "" && Nexus.Browse.read(url, timeout: 15_000) do
                    {:ok, text} -> String.slice(str(text), 0, 2200)
                    _ -> str(r["description"] || r[:description])
                  end

                "SOURCE (#{q}): #{url}\n#{body}"
              end)

            other ->
              issue("web search failed for #{inspect(q)}: #{inspect(other) |> String.slice(0, 120)}")
              []
          end
        end)

      {:ok, s, Enum.join(harvest, "\n\n---\n\n")}
    end
  end

  defp extract_html(reply) do
    case Regex.run(~r/===\s*html\s*===\s*\n(.*)\z/s, reply) do
      [_, h] -> h |> String.replace(~r/^```(html)?\s*\n?/m, "") |> String.replace(~r/```\s*\z/, "") |> String.trim()
      _ ->
        case Regex.run(~r/<!doctype html.*<\/html>/is, reply) do
          [h] -> h
          _ -> ""
        end
    end
  end

  defp roll_day(s) do
    today = Date.to_iso8601(Date.utc_today())
    if s.day == today, do: s, else: %{s | day: today, llm_calls: 0}
  end

  defp heartbeat(s) do
    File.write!(
      Path.join(artifacts(), "state.txt"),
      "ts: #{System.os_time(:second)}\nday: #{s.day}\ncycles: #{s.cycles}\nllm_calls: #{s.llm_calls}\nwork_cycles: #{s.work_cycles}\ngenesis_step: #{s.genesis_step}\ndeploys: #{s.deploys}\nsite: #{s.site_url}\n"
    )

    File.write!(Path.join(artifacts(), "uptime.log"), "#{System.os_time(:second)}\n", [:append])
    s
  end

  defp issue(msg) do
    File.write!(Path.join(artifacts(), "issues.log"), "#{DateTime.to_iso8601(DateTime.utc_now())} | #{msg}\n", [:append])
    log("ISSUE: #{msg}")
    true
  end

  defp log(msg) do
    Autopoet.Log.puts("venture: #{msg}")
  rescue
    _ -> Logger.info("venture: #{msg}")
  end

  defp artifacts, do: System.get_env("AUTOPOET_DESK_DIR") || "eval/venture"

  defp write_body(path, content), do: safe_body(fn -> Autopoet.Body.apply(%{path => content}, %{}) end, path)
  defp append_body(path, content), do: safe_body(fn -> Autopoet.Body.apply(%{}, %{path => content}) end, path)

  defp safe_body(fun, path) do
    fun.()
  rescue
    e -> issue("body write #{path} failed: #{Exception.message(e)}")
  end

  defp read_body(path) do
    case File.read(Path.join(Autopoet.Body.root(), path)) do
      {:ok, c} -> String.slice(c, 0, 4000)
      _ -> "(no #{path} yet)"
    end
  rescue
    _ -> "(no #{path} yet)"
  end

  defp str(v) when is_binary(v), do: v
  defp str(nil), do: ""
  defp str(v), do: inspect(v)
end
