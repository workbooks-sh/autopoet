defmodule Autopoet.Intake do
  @moduledoc """
  The intake agent — runs once, between the quiz finale and the first dashboard
  paint, and turns the profile (`data/profile`: quiz answers, dictated notes,
  compiled `plan.*` lines) into a LIVING first world. Four lanes, per
  docs/onboarding-bootstrap-plan.md:

    * LANE A (here, deterministic): expand `plan.*` into body `.work` files —
      workspace pages, REAL `agent :` blocks (policy from the leash/pings/oops
      answers), rules staged `#proposed`, a briefing page carrying the human's
      dictated notes verbatim. Zero network, zero keys, always completes.
      Applied via `Body.apply` (undoable) + `Agents.register_from_body()`.
    * IGNITION: if keys exist, the first agent takes its first canned task
      (`plan.firstrun`) so the graph is MOVING at first paint.
    * LANE B (optional): one brain-shaped pass (`Brain.propose`) rewrites the
      skeleton in the user's own vocabulary. No keys → clean skip.
    * LANE D: the FIRST PROPOSAL — `Proposals.record`'s first real producer.
      The human-facing vault workspace + the go-forward brief arrive as one
      pending proposal; the dashboard opens on it (intake.js overlay).

  Guarded by `data/bootstrapped` — runs exactly once per install; `start/0` is
  async and never blocks the caller.
  """

  @agent_model "xiaomi/mimo-v2.5"

  def marker, do: Path.join([Autopoet.Discovery.home(), "data", "bootstrapped"])
  def ran?, do: File.exists?(marker())

  @doc "Kick the intake asynchronously, once. Returns :started | :already."
  def start do
    if ran?() do
      :already
    else
      File.mkdir_p!(Path.dirname(marker()))
      File.write!(marker(), "started\n")
      Task.start(fn -> run() end)
      :started
    end
  end

  @doc "The full pipeline, synchronous. Safe to call directly in tests."
  def run do
    profile = Autopoet.Profile.all()
    plan = parse_plan(profile)

    Autopoet.Log.puts("intake: building your starting world (#{plan.workspace.name})")
    files = skeleton(profile, plan)
    {:ok, _} = Autopoet.Body.apply(files)
    Autopoet.Agents.register_from_body()
    seed_prior(plan)
    Autopoet.Log.puts("intake: #{map_size(files)} pages live — agents registered")

    ignite(plan)
    enrich(profile, plan)
    personalize(profile, plan)
    propose_first(profile, plan)

    File.write!(marker(), "done\n")
    Autopoet.Log.puts("intake: done — the first proposal is waiting")
    :ok
  end

  # ── plan parsing (the quiz's plan.* line contract) ──────────────────────────

  @doc false
  def parse_plan(profile) do
    {ws_name, ws_desc} = split_pair(profile["plan.workspace"] || "notebook — scratch, library")

    %{
      workspace: %{
        name: slug(ws_name),
        title: ws_name,
        pages: ws_desc |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      },
      agents:
        for n <- 1..4, v = profile["plan.agent.#{n}"], v != nil do
          {name, job} = split_pair(v)
          %{name: name, slug: String.replace(slug(name), "-", "_"), job: job}
        end,
      rules: for(n <- 1..5, v = profile["plan.rule.#{n}"], v != nil, do: v),
      setting: profile["plan.setting"] || "",
      fleet: profile["plan.fleet"],
      connect:
        (profile["plan.connect"] || "") |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")),
      firstrun: profile["plan.firstrun"]
    }
  end

  defp split_pair(line) do
    case String.split(line || "", " — ", parts: 2) do
      [a, b] -> {String.trim(a), String.trim(b)}
      [a] -> {String.trim(a), ""}
    end
  end

  defp slug(s),
    do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

  # ── lane A: the deterministic skeleton ──────────────────────────────────────

  @doc false
  def skeleton(profile, plan) do
    ws = plan.workspace

    pages =
      for page <- ws.pages, into: %{} do
        {"#{ws.name}/#{slug(page)}.work",
         """
         # #{page}

         Part of [[#{ws.name}/index]]. This page holds #{page} — the agents keep it
         current; you edit it like any other text. Empty is honest: nothing has
         happened yet.
         """}
      end

    base = %{
      "#{ws.name}/index.work" => ws_index(profile, plan),
      "#{ws.name}/agents.work" => agents_page(plan),
      "#{ws.name}/rules.work" => rules_page(plan),
      "intake/briefing.work" => briefing(profile)
    }

    base
    |> Map.put("intake/scout.work", scout_page())
    |> Map.merge(pages)
    |> Map.merge(
      if plan.firstrun,
        do: %{"intake/firstrun.work" => firstrun_page(plan)},
        else: %{}
    )
  end

  # Lane C's worker: a consent-scoped scout. It only ever receives EXPLICIT
  # picks (scan.* profile lines written by the enrichment interviews) — it is
  # never told to go looking on its own.
  defp scout_page do
    """
    # the scout

    A disposable agent for enrichment: it reads ONLY what the human explicitly
    picked at setup (repos, zones, docs), writes what it learned into
    intake/context pages, and vanishes. It never widens its own scope.

    agent :intake_scout do
      prompt \"\"\"
      You are the intake scout: one consent-scoped errand, then you vanish.
      You will be given EXPLICIT picks the human made (repository names, zone
      names, document names). Fetch ONLY those — public endpoints via the web
      verbs (fetch <url>, scrape <url>). For each pick, write a short plain
      brief: what it is, what it suggests about the human's world, anything an
      agent serving them should know. Never fetch anything not named in your
      task. Report back the briefs, one per pick.
      \"\"\"
      model "#{@agent_model}"
      tools coreutils
      grant net
      management frozen
    end
    """
  end

  defp ws_index(profile, plan) do
    ws = plan.workspace
    links = Enum.map_join(ws.pages, " · ", &"[[#{ws.name}/#{slug(&1)}]]")

    """
    # #{ws.title}

    Your starting workspace, built from your setup answers
    (#{profile["intent"] || "?"}#{if profile["industry"], do: " · " <> profile["industry"], else: ""}).

    Pages: #{links}
    Crew: [[#{ws.name}/agents]] — Rules: [[#{ws.name}/rules]] — You: [[intake/briefing]]
    """
  end

  defp agents_page(plan) do
    ws = plan.workspace

    blocks =
      Enum.map_join(plan.agents, "\n", fn a ->
        """
        agent :#{a.slug} do
          prompt \"\"\"
          You are #{a.name} — your standing job: #{a.job}.
          Policy, from the human's own setup answers: #{plan.setting}.
          #{if plan.fleet, do: "Fleet: #{plan.fleet}.", else: ""}
          Work inside [[#{ws.name}/index]]; read [[intake/briefing]] to know who
          you serve — their words are in it, verbatim. Keep your pages current.
          If anything is missing, broken, or beyond your grant:
          `request self '<what needs to change>'` and continue. Never wait.
          \"\"\"
          model "#{@agent_model}"
          tools coreutils
          management frozen
        end
        """
      end)

    """
    # the crew

    The standing agents of [[#{ws.name}/index]] — declared here, registered live.
    A human edits their grants; they never widen their own.

    #{blocks}
    """
  end

  defp rules_page(plan) do
    rules =
      plan.rules
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {rule, n} ->
        """
        ## rule #{n} #proposed

        #{rule}

        Staged, not armed. Arming gives it a real trigger; until then it is a
        promise in plain words.
        """
      end)

    """
    # rules — staged

    Written in your words at setup. Each is inert until you arm it.

    #{rules}
    """
  end

  defp briefing(profile) do
    answers =
      profile
      |> Enum.reject(fn {k, _} -> String.starts_with?(k, "plan.") or String.ends_with?(k, ".notes") end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{v}" end)

    notes =
      profile
      |> Enum.filter(fn {k, v} -> String.ends_with?(k, ".notes") and String.trim(v) != "" end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {k, v} ->
        "- on #{String.trim_trailing(k, ".notes")}: “#{String.trim(v)}”"
      end)

    """
    # briefing — who you serve

    Everything the human said at setup. Their words below are VERBATIM — treat
    them as standing instruction, senior to anything inferred.

    ## answers
    #{answers}

    ## their notes, in their own words
    #{if notes == "", do: "(none left — the answers are the whole brief)", else: notes}
    """
  end

  defp firstrun_page(plan) do
    """
    # first run

    #{plan.firstrun}

    This is the ignition move — the first visible work, queued the moment the
    world exists. Its results land in [[#{plan.workspace.name}/index]].
    """
  end

  # ── ignition ────────────────────────────────────────────────────────────────

  defp ignite(%{firstrun: nil}), do: :skip
  defp ignite(%{agents: []}), do: :skip

  defp ignite(plan) do
    # :ignition (app env, default true) — eval harnesses set false: a live agent
    # dispatched at intake is REAL agent work whose spend rides Nexus.Llm, not
    # the harness's brain-wrapped cost meter (found live: the long rehearsal's
    # intake ignited a shopkeeper agent outside the spend cap)
    if Application.get_env(:autopoet, :ignition, true) and Autopoet.Providers.openrouter?() do
      first = hd(plan.agents)

      Autopoet.Agents.dispatch(
        first.slug,
        """
        FIRST RUN. #{plan.firstrun}
        Read [[intake/briefing]] and the [[#{plan.workspace.name}/index]] pages, then do
        the first honest pass of your standing job (#{first.job}) with what exists
        locally. Report what you did and what you need next.
        """
      )

      Autopoet.Log.puts("intake: ignition — #{first.name} is on its first task")
    else
      Autopoet.Log.puts("intake: no LLM keys — skipping ignition (world is built, idle)")
    end
  rescue
    e -> Autopoet.Log.puts("intake: ignition failed softly (#{Exception.message(e)})")
  end

  # ── lane C: enrichment — consume the consent lines, dispatch the scout ──────
  # The enrichment interview screens (post-finale, per connected provider) write
  # `scan.<provider>: pick1,pick2` lines. Whatever is there, the scout fetches —
  # ONLY that. No lines, no scan. (Interviews ship with real OAuth, wb-y9of;
  # public picks — e.g. public github repos — already work today.)
  @doc false
  def scans(profile) do
    for {"scan." <> provider, v} <- profile,
        picks = v |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")),
        picks != [],
        do: {provider, picks}
  end

  defp enrich(profile, _plan) do
    case scans(profile) do
      [] ->
        :skip

      list ->
        if Autopoet.Providers.openrouter?() do
          for {provider, picks} <- list do
            Autopoet.Agents.dispatch(
              "intake_scout",
              """
              Consent-scoped enrichment. Provider: #{provider}.
              The human explicitly picked these — fetch ONLY these, nothing else:
              #{Enum.map_join(picks, "\n", &"- #{&1}")}
              Write one short brief per pick; report all briefs back.
              """,
              file_to: "intake/context-#{provider}.work"
            )
          end

          Autopoet.Log.puts("intake: scout dispatched for #{Enum.map_join(list, ", ", &elem(&1, 0))}")
        end
    end
  rescue
    e -> Autopoet.Log.puts("intake: enrichment skipped (#{Exception.message(e)})")
  end

  # ── lane B: personalization (optional, brain-shaped) ────────────────────────

  defp personalize(profile, plan) do
    Autopoet.Brain.propose(%{
      target: "#{plan.workspace.name}/index.work",
      kind: "intake.personalize",
      goal:
        "rewrite the intake skeleton's PROSE in this human's own vocabulary " <>
          "(industry + notes below). Keep every file's structure, links, and " <>
          "agent blocks intact. The vault pages' `## what this is`, `## how it " <>
          "fills`, and `## first moves` headings are PROTECTED STRUCTURE — " <>
          "rewrite the prose under them, never the headings themselves. Then " <>
          "make rule 1 in #{plan.workspace.name}/rules.work " <>
          "its simplest genuinely runnable form against what exists locally.",
      profile: Autopoet.Profile.render(),
      industry: profile["industry"]
    })
  rescue
    e -> Autopoet.Log.puts("intake: personalization skipped (#{Exception.message(e)})")
  end

  # ── lane D: the first proposal ──────────────────────────────────────────────

  @doc "The pending intake proposal, if any: {id, brief_text} | nil."
  def pending_proposal do
    Autopoet.Proposals.pending()
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.find_value(fn id ->
      target = Path.join([Autopoet.Proposals.dir(), id, "target"])

      with {:ok, "intake" <> _} <- File.read(target),
           # the brief nests inside the workspace (genesis I7 — no vault-root
           # strays); dual-key: old installs' root first-proposal.md still found
           brief when is_binary(brief) <-
             Autopoet.Proposals.changes(id)
             |> Enum.find_value(fn {rel, src} ->
               if Path.basename(rel) == "first-proposal.md", do: src
             end) do
        {id, brief}
      else
        _ -> nil
      end
    end)
  end

  defp propose_first(profile, plan) do
    if pending_proposal() do
      :already
    else
      Autopoet.Proposals.record(
        %{target: "intake", kind: "intake.brief"},
        first_changes(profile, plan)
      )
    end
  end

  @doc """
  The complete first-proposal change set — the GENERATED VAULT (genesis I4/I5).
  Pure function of profile+plan: the golden-manifest source the genesis evals
  assert against.
  """
  def first_changes(profile, plan) do
    ws = plan.workspace

    %{
      "#{ws.name}/.workspace" => "",
      "#{ws.name}/index.md" => vault_index(plan),
      "#{ws.name}/first-proposal.md" => brief(profile, plan)
    }
    |> Map.merge(
      for page <- ws.pages, into: %{} do
        {"#{ws.name}/#{slug(page)}.md", vault_page(profile, plan, page)}
      end
    )
  end

  @doc """
  Plan-derived GENOME PRIOR edges (D1, wb-h0tjs.5): the starting pathways a
  fresh workspace plausibly walks — index ↔ every page, page-to-page chain, and
  the bare event-target name → its page (an `orders` event warms shop/orders).
  Seeded as small pseudo-count mass; live traffic overrules in minutes.
  """
  def prior_edges(plan) do
    ws = plan.workspace.name
    index = "#{ws}/index.work"
    pages = for p <- plan.workspace.pages, do: {p, "#{ws}/#{slug(p)}.work"}
    rels = Enum.map(pages, &elem(&1, 1))

    index_edges = Enum.flat_map(rels, &[{index, &1}, {&1, index}])
    chain_edges = rels |> Enum.chunk_every(2, 1, :discard) |> Enum.flat_map(fn [a, b] -> [{a, b}, {b, a}] end)
    target_edges = for {title, rel} <- pages, do: {slug(title), rel}

    Enum.uniq(index_edges ++ chain_edges ++ target_edges)
  end

  defp seed_prior(plan) do
    Autopoet.Shadow.Hebb.seed_prior(prior_edges(plan))
    Autopoet.Shadow.Hebb.seed_prior(semantic_prior(plan))
  rescue
    _ -> :ok
  end

  # D3: semantic birth edges among the workspace loci (embeddings nominate). The
  # locus text is the page's own title/prose — the same signal the graph carries.
  defp semantic_prior(plan) do
    ws = plan.workspace.name

    loci =
      for page <- plan.workspace.pages do
        {"#{ws}/#{slug(page)}.work", "#{page} #{plan.workspace.title}"}
      end

    if length(loci) >= 2, do: Autopoet.Genome.semantic_edges(loci), else: []
  rescue
    _ -> []
  end

  # ── the genome: road-specific starting code (genesis I4, wb-h0tjs.2) ────────
  # A vault page is STARTING CODE, not a placeholder: three protected sections a
  # human can work with immediately. Resolution: the intent-road's genome
  # template (priv/genomes/<key>/<page-slug>.md.eex, else <key>/_page.md.eex),
  # else the generic. Deterministic EEx, zero-LLM (Lane A); Lane B rewrites the
  # prose under the headings only.

  @doc false
  def genome_key(profile) do
    case profile["intent"] do
      "money" -> "money-#{profile["money_road"] || "sell"}"
      "productivity" -> "productivity"
      "delegate" -> "delegate"
      "build" -> if profile["build_what"] in ["site", "store"], do: "build-site", else: "build-tool"
      _ -> "blank"
    end
  end

  defp vault_page(profile, plan, page) do
    assigns = page_assigns(plan, page)
    key = genome_key(profile)
    dir = Path.join(:code.priv_dir(:autopoet), "genomes/#{key}")

    template =
      Enum.find(
        [Path.join(dir, "#{slug(page)}.md.eex"), Path.join(dir, "_page.md.eex")],
        &File.exists?/1
      )

    if template do
      EEx.eval_file(template, assigns: assigns)
    else
      generic_vault_page(assigns)
    end
  end

  defp page_assigns(plan, page) do
    fills =
      case plan.agents do
        [] ->
          "Nothing automatic yet — this world starts quiet. Whatever you write here is the seed your future crew reads first."

        agents ->
          crew = Enum.map_join(agents, ", ", & &1.name)
          rules = length(plan.rules)

          "Your crew (#{crew}) works this workspace" <>
            if(rules > 0,
              do: "; #{rules} staged rule(s) wait for you to arm them. Until then, what you write here is what they read.",
              else: ". What you write here is what they read."
            )
      end

    moves =
      [
        "write one real thing on this page — the crew reads the vault, not your mind",
        case plan.connect do
          [first | _] -> "connect #{first} — it feeds #{page} real data"
          [] -> "keep it local — this page works with zero connections"
        end,
        if(plan.rules != [],
          do: "arm rule 1 on the graph when you trust it — it starts watching",
          else: "ask for a rule when a chore repeats — plain words are enough"
        )
      ]
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. #{m}" end)

    [
      page: page,
      ws: plan.workspace.title,
      crew: Enum.map_join(plan.agents, ", ", & &1.name),
      rules: plan.rules,
      connect: plan.connect,
      fills: fills,
      moves: moves
    ]
  end

  defp generic_vault_page(a) do
    """
    # #{a[:page]}

    ## what this is
    The #{a[:page]} page of your #{a[:ws]} workspace — starting code built from your setup answers, yours to edit.

    ## how it fills
    #{a[:fills]}

    ## first moves
    #{a[:moves]}
    """
  end

  defp vault_index(plan) do
    ws = plan.workspace

    """
    # #{ws.title}

    Your workspace. Set up from your answers; every page is yours to edit.

    Pages: #{Enum.map_join(ws.pages, " · ", &"[[#{ws.name}/#{slug(&1)}]]")}
    """
  end

  @doc false
  def brief(profile, plan) do
    ws = plan.workspace

    agents =
      case plan.agents do
        [] -> "- (no standing agents yet — the blank world starts quiet)"
        list -> Enum.map_join(list, "\n", &"- #{&1.name} — #{&1.job}")
      end

    rules =
      case plan.rules do
        [] -> "- (none staged)"
        list -> list |> Enum.with_index(1) |> Enum.map_join("\n", fn {r, n} -> "- rule #{n}: #{r}" end)
      end

    connect =
      case plan.connect do
        [] -> "nothing yet — it works with zero connections"
        [first | _] = all -> "#{Enum.join(all, ", ")} — start with #{first}; it feeds the agents real data"
      end

    """
    # your first proposal

    I set up a starting world from your answers — before you ever saw the
    dashboard. Accepting this proposal lands the #{ws.title} workspace in your
    vault. Nothing else changes without you.

    ## what exists now
    - workspace **#{ws.title}** — #{Enum.join(ws.pages, ", ")}
    - the crew, registered and standing by:
    #{agents}
    - rules staged (inert until you arm them):
    #{rules}

    ## what runs first
    #{plan.firstrun || "nothing is queued — say the word and something will be"}

    ## the next three moves
    1. accept this proposal — the workspace lands in your vault
    2. connect: #{connect}
    3. arm rule 1 when you trust it — it starts watching

    ## the fine print#{if profile["industry"], do: " (your world: #{profile["industry"]})", else: ""}
    It is all just text. Every page can be edited, every change is undoable,
    and I keep receipts on everything I do.
    """
  end
end
