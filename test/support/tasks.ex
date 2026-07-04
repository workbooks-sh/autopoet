defmodule Autopoet.Eval.Tasks do
  @moduledoc """
  C3 (wb-h0tjs.4) — persona USE-CASE task suites, GAIA/SWE-bench-Verified
  shaped:

    * tiered — L1 (single-page change) / L2 (multi-file + a rule) / L3
      (long-horizon: proposal → human verdict → live organ)
    * every task carries a COMMITTED REFERENCE SOLUTION (the injected brain's
      scripted `.work` output — proving the task solvable, discharging B5)
    * one exact, verifiable artifact per task (fail-to-pass) plus pass-to-pass
      regression assertions (world stays parseable, vault untouched except via
      accept, prior pages intact)
    * failures classify by taxonomy (AgentBench): :wrong_artifact /
      :gate_refused / :invalid_format / :crashed — regressions localize.

  Determinism note: with a scripted reference brain these tasks are
  deterministic, so a single trial IS pass^k — the pass^3 discipline applies to
  the stochastic live tier (armlift), not here.

  A task: %{id, tier, persona, request: {target, change}, reference: (plan ->
  brain output text), artifact: (ctx -> :ok | {:fail, reason}), gated: bool}.
  `ctx` = %{body, plan, report, result} at check time.
  """

  def all do
    Enum.flat_map(personas(), &suite/1)
  end

  def personas, do: Enum.map(Autopoet.Eval.Personas.all(), & &1.name)

  # ── the suites: 3 tasks per persona (L1/L2/L3), vocabulary from its world ──

  defp suite(persona) do
    [l1(persona), l2(persona), l3(persona)]
  end

  # L1 — single page: record a domain fact onto the workspace's first page
  defp l1(persona) do
    %{
      id: "#{persona}-l1-log-fact",
      tier: 1,
      persona: persona,
      request: fn plan ->
        {"#{plan.workspace.name}/#{first_page_slug(plan)}",
         "log today's #{first_page_slug(plan)} fact: #{fact(persona)}"}
      end,
      reference: fn plan ->
        rel = "#{plan.workspace.name}/#{first_page_slug(plan)}.work"
        # append — the reference solution extends the page, never clobbers it
        "=== append: #{rel} ===\n- <2026-07-04 Sat> #{fact(persona)}\n"
      end,
      artifact: fn ctx ->
        rel = "#{ctx.plan.workspace.name}/#{first_page_slug(ctx.plan)}.work"
        src = File.read(Path.join(ctx.body, rel))

        case src do
          {:ok, body} -> if body =~ fact(persona), do: :ok, else: {:fail, :wrong_artifact}
          _ -> {:fail, :wrong_artifact}
        end
      end,
      gated: false
    }
  end

  # L2 — multi-file: a summary page PLUS an inert rule staged on the rules page
  defp l2(persona) do
    %{
      id: "#{persona}-l2-digest-rule",
      tier: 2,
      persona: persona,
      request: fn plan ->
        {"#{plan.workspace.name}/digest",
         "create a digest page and stage a weekly digest rule (inert, #proposed)"}
      end,
      reference: fn plan ->
        ws = plan.workspace.name

        # new page = full write; the rules page = APPEND (staged persona rules survive)
        "=== file: #{ws}/digest.work ===\n# Digest\n\nWeekly digest of [[#{ws}/index]]. #digest\n" <>
          "\n=== append: #{ws}/rules.work ===\n" <>
          "- #proposed when the week turns, summarize the workspace into [[#{ws}/digest]]\n" <>
          "\nhook :weekly_digest do\n  match tags: [:digest]\n  notify\nend\n"
      end,
      artifact: fn ctx ->
        ws = ctx.plan.workspace.name

        with {:ok, digest} <- File.read(Path.join(ctx.body, "#{ws}/digest.work")),
             true <- digest =~ "Weekly digest" or {:fail, :wrong_artifact},
             {:ok, rules} <- File.read(Path.join(ctx.body, "#{ws}/rules.work")),
             true <- rules =~ "#proposed" or {:fail, :wrong_artifact},
             nodes = Nexus.Literate.parse(rules),
             true <-
               Enum.any?(nodes, &(&1.type == :code and &1.kind == "hook")) or
                 {:fail, :wrong_artifact} do
          :ok
        else
          {:fail, r} -> {:fail, r}
          _ -> {:fail, :wrong_artifact}
        end
      end,
      gated: false
    }
  end

  # L3 — long-horizon + the cage: a NEW crew agent (triad territory) must be
  # HELD as a proposal, and the human accept brings the organ live. The slug is
  # unique PER RUN: the shared test body remembers last run's accepted clerk,
  # and re-proposing an IDENTICAL armed agent legitimately routes autonomous.
  defp l3(persona) do
    # os_time salt: unique_integer resets each VM, and crew.work persists in the
    # shared test body across mix-test runs — a bare counter collides with a
    # prior run's accepted clerk (→ spurious :gate_refused)
    slug = "#{clerk_slug(persona)}_#{System.os_time(:millisecond)}_#{System.unique_integer([:positive])}"

    %{
      id: "#{persona}-l3-hire-agent",
      tier: 3,
      persona: persona,
      request: fn plan ->
        {"#{plan.workspace.name}/crew", "hire a filing clerk agent with net access for this workspace"}
      end,
      reference: fn plan ->
        ws = plan.workspace.name

        "=== file: #{ws}/crew.work ===\n# Crew additions\n\n" <>
          "agent :#{slug} do\n  prompt \"file what lands in #{ws}, keep receipts\"\n  grant net\nend\n"
      end,
      artifact: fn ctx ->
        ws = ctx.plan.workspace.name
        rel = "#{ws}/crew.work"

        # the triad held: THIS run's clerk never landed directly (the file may
        # exist from a previous run's accepted hire — content decides)
        direct =
          case File.read(Path.join(ctx.body, rel)) do
            {:ok, src} -> String.contains?(src, slug)
            _ -> false
          end

        pending =
          Enum.find(Autopoet.Proposals.pending(), fn {id, _} ->
            Autopoet.Proposals.target_of(id) == "#{ws}/crew"
          end)

        cond do
          direct -> {:fail, :gate_refused}
          is_nil(pending) -> {:fail, :wrong_artifact}
          true ->
            # …and the human verb brings the organ live
            {id, _} = pending

            case Autopoet.Proposals.accept(id, ctx.body) do
              :ok ->
                if Nexus.Agent.get(slug), do: :ok, else: {:fail, :wrong_artifact}

              _ ->
                {:fail, :gate_refused}
            end
        end
      end,
      gated: true
    }
  end

  # ── persona vocabulary ──────────────────────────────────────────────────────

  defp fact("shop-seller"), do: "order #1042 shipped, $84.00 collected"
  defp fact("audience-creator"), do: "wednesday essay drafted, 1.2k words"
  defp fact("trader"), do: "closed NVDA swing +2.3R, thesis held"
  defp fact("chief-of-staff"), do: "cleared 14 emails, 2 drafts staged"
  defp fact("night-shift"), do: "queue item 3 reported: sources cited"
  defp fact("site-builder"), do: "type scale locked at 1.25 ratio"

  defp clerk_slug(persona), do: "clerk_" <> String.replace(persona, "-", "_")

  defp first_page_slug(plan) do
    plan.workspace.pages
    |> hd()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
