defmodule Autopoet.PersonaEvalTest do
  @moduledoc """
  LANE E — the persona evaluation suite (docs/onboarding-bootstrap-plan.md §7).

  Every golden persona (test/support/personas.ex, quiz-faithful) seeds a full
  intake run through the REAL production path — Profile → Intake.run (Lanes A+D,
  no LLM, no network) — then the persona's synthetic world pulses the real bus
  and the learning layers must move:

    SEED    profile lines in, marker cleared, stale intake proposals rejected
    INTAKE  world parses · agents register · exactly ONE pending intake proposal ·
            rules staged inert (#proposed) · human notes verbatim in the briefing ·
            brief promises only what exists (agents, connect order, firstrun)
    LIVE    pulse events → Hebbian pathways form over persona loci · recall
            actuator ranks them · capture trace grows
    REWARD  accepting the proposal lands in the outcome ledger (the labeled
            reward stream) and materializes the workspace in the vault

  Run as a scorecard: mix test test/persona_eval_test.exs
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.Personas

  # personas share one app home; each test rebuilds profile + intake world
  setup do
    on_exit(fn -> Autopoet.Profile.clear() end)
    :ok
  end

  for persona <- Personas.all() do
    @persona persona
    test "persona #{persona.name}: intake → live world → learning loop" do
      p = @persona

      # ── SEED ──────────────────────────────────────────────────────────────
      Autopoet.Profile.clear()
      for {k, v} <- p.profile, do: :ok = Autopoet.Profile.put(k, v)

      File.rm(Autopoet.Intake.marker())

      case Autopoet.Intake.pending_proposal() do
        {stale, _} -> Autopoet.Proposals.reject(stale, "eval reseed")
        nil -> :ok
      end

      # ── INTAKE (Lanes A+D through the real pipeline; B/C skip keyless) ────
      assert :ok = Autopoet.Intake.run()

      profile = Autopoet.Profile.all()
      plan = Autopoet.Intake.parse_plan(profile)
      assert plan.workspace.name == p.workspace
      score(p.name, "plan parses — workspace #{plan.workspace.name}, #{length(plan.agents)} agent(s), #{length(plan.rules)} rule(s)")

      # every skeleton file landed in the body and parses in the real Literate lane
      files = Autopoet.Intake.skeleton(profile, plan)
      body = Autopoet.Body.root()

      for {rel, _} <- files do
        path = Path.join(body, rel)
        assert File.exists?(path), "#{p.name}: skeleton file missing from body: #{rel}"
        nodes = Nexus.Literate.parse(File.read!(path))
        assert is_list(nodes), "#{p.name}: #{rel} does not parse"
      end

      score(p.name, "world parses — #{map_size(files)} pages live in the body")

      # agents from the plan are REGISTERED, runnable organs
      for a <- plan.agents do
        assert Nexus.Agent.get(a.slug), "#{p.name}: agent #{a.slug} not registered"
      end

      assert Enum.map(plan.agents, & &1.slug) |> List.first() == p.first_agent
      score(p.name, "agents registered — #{Enum.map_join(plan.agents, ", ", & &1.slug)}")

      # rules staged INERT — real prose, tagged for the human to arm
      if plan.rules != [] do
        rules_src = File.read!(Path.join(body, "#{plan.workspace.name}/rules.work"))
        assert rules_src =~ "#proposed"
        for r <- plan.rules, do: assert(rules_src =~ r)
        score(p.name, "#{length(plan.rules)} rule(s) staged inert (#proposed)")
      end

      # the human's own words, verbatim, attributed
      assert File.read!(Path.join(body, "intake/briefing.work")) =~ p.note
      score(p.name, "human notes carried verbatim into the briefing")

      # exactly ONE pending intake proposal, promising only what exists
      assert {id, brief} = Autopoet.Intake.pending_proposal()
      others = Autopoet.Proposals.pending() |> Enum.filter(fn {pid, _} -> Autopoet.Proposals.target_of(pid) == "intake" end)
      assert length(others) == 1

      assert brief =~ plan.workspace.title
      for a <- plan.agents, do: assert(brief =~ a.name)
      if plan.connect != [], do: assert(brief =~ "start with #{p.connect_head}")
      if plan.firstrun, do: assert(brief =~ plan.firstrun)
      score(p.name, "exactly one pending proposal; brief promises only what exists")

      # ── LIVE: the persona's world pulses the real bus ─────────────────────
      hebb0 = Autopoet.Shadow.Hebb.stats()
      cap0 = Autopoet.Capture.count()

      for _ <- 1..25, ev <- p.pulse do
        Nexus.Events.emit(Map.put(ev, :tags, []))
      end

      Process.sleep(400)

      hebb = Autopoet.Shadow.Hebb.stats()
      assert hebb.events >= hebb0.events + 25 * length(p.pulse) - 5
      assert Autopoet.Capture.count() > cap0

      # pathways formed over THIS persona's loci, and the actuator recalls them:
      # consecutive pulse loci must be linked in the learned graph
      [first, second | _] = Enum.map(p.pulse, &pulse_locus/1)
      recalled = Autopoet.Shadow.Hebb.recall(first, 8)
      assert recalled != [], "#{p.name}: no recall from locus #{first}"
      assert second in Enum.map(recalled, &elem(&1, 0)),
             "#{p.name}: pathway #{first} → #{second} not learned (got #{inspect(recalled)})"

      score(p.name, "learning moved — +#{hebb.events - hebb0.events} events, recall(#{first}) → #{second}")

      # ── REWARD: the human verb closes the loop ────────────────────────────
      accepted0 = Autopoet.Shadow.Outcomes.stats().proposals.accepted
      assert :ok = Autopoet.Proposals.accept(id, Autopoet.Notes.dir())

      # the workspace materialized in the vault via the accept path
      assert File.exists?(Path.join([Autopoet.Notes.dir(), plan.workspace.name, "index.md"]))

      Process.sleep(300)
      outcomes = Autopoet.Shadow.Outcomes.stats()
      assert outcomes.proposals.accepted >= accepted0 + 1
      assert %{accepted: n} = Autopoet.Shadow.Outcomes.ledger().proposals["intake"]
      assert n >= 1

      score(p.name, "reward landed — accept recorded in the outcome ledger (intake: #{n})")
    end
  end

  defp pulse_locus(ev), do: to_string(ev[:doc] || ev[:target] || ev[:kind])

  defp score(name, msg), do: IO.puts("  ✓ PERSONA #{name} — " <> msg)
end
