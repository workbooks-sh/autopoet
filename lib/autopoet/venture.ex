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
      agenda_idx: 0,
      work_cycles: 0,
      deploys: 0,
      site_url: nil,
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
      if charter?(), do: venture_cycle(s), else: genesis_step(s)
    else
      s
    end
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
         {:ok, s, reply} <- think(s, :feedback, feedback_prompt(harvest), max_tokens: 1600) do
      append_body("venture/feedback.work", "\n## feedback #{s.day} ##{s.work_cycles + 1}\n\n" <> reply)
      %{s | work_cycles: s.work_cycles + 1}
    end
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

    case System.cmd("wrangler", ["pages", "deploy", site_dir, "--project-name=#{project}", "--branch=main", "--commit-dirty=true"], stderr_to_stdout: true) do
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

  # site signals: waitlist/analytics when wired; empty until then (the measure
  # prompt journals honestly about having no data yet)
  defp site_signals(_s), do: []

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
    You are the venture desk, BUILD slot. Your charter:
    #{charter()}
    Current deployed site: #{s.site_url || "(none yet)"}
    Latest feedback:
    #{String.slice(read_body("venture/feedback.work"), 0, 1500)}

    Produce the COMPLETE landing page for the product (or a sharp iteration of
    the current one, folding in feedback): single self-contained HTML file —
    inline CSS, no external assets, mobile-first, a waitlist form (mailto: or
    form action to /api/waitlist placeholder is fine for now), honest copy that
    speaks the ICP's language from your research. Emit ONE block:

    === html ===
    <the complete html>
    """
  end

  defp feedback_prompt(harvest) do
    """
    You are the venture desk, FEEDBACK slot. Your charter niche:
    #{charter_section("Niche")}

    FRESH WEB EVIDENCE:
    #{harvest}

    Synthesize: what practitioners are saying that CONFIRMS or THREATENS your
    thesis; feature demands worth folding into the landing page; objections
    your copy must answer. Concrete quotes, then 3 actionable changes.
    """
  end

  defp market_prompt(s) do
    """
    You are the venture desk, MARKET slot. Charter GTM:
    #{charter_section("GTM")}
    Site: #{s.site_url || "(not deployed yet)"}

    Draft this slot's outbound: 3 X posts (each standalone, practitioner voice,
    no hype-slop, one insight each; max 260 chars each) + 1 community post
    (300 words, gives real value first, product mentioned once at the end).
    These go to the HUMAN for approval before posting — write them ready-to-ship.
    """
  end

  defp measure_prompt(s, signals) do
    """
    You are the venture desk, MEASURE slot. Charter validation test:
    #{charter_section("Validation")}
    Site: #{s.site_url || "(not deployed)"} · deploys so far: #{s.deploys}
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
