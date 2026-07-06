defmodule Autopoet.Eval.LiveRunner do
  @moduledoc """
  v2-2 (wb-4k6fp.2) — the LIVE tier runner, monitoring-first by design (owner
  decree: never "let it loose and then it just fails a bunch"):

    * every task writes a FULL TRANSCRIPT (prompt → response, per round) to
      eval/live-runs/<stamp>/<task>.md — the review ritual has material.
    * the ONLY live surface is the brain's completions: we wrap `:brain_llm`
      around the real provider call, so prompt assembly, routing, gates, and
      artifact checks are all the production path — but agents/ignition stay
      DEAD (no unmonitored fan-out, no surprise spend).
    * spend is capped structurally: max_tokens per call, tasks run one at a
      time, the run stops early if `max_error_streak` tasks fail in a row.
    * the first runs are OBSERVATIONAL: the report grades, it does not gate —
      gates get pre-registered only after a reviewed baseline (the discipline).

  Returns the summary map; writes report.md + history line.
  """

  alias Autopoet.Eval.{Personas, Tasks}

  def run(persona_name, opts \\ []) do
    stamp = Keyword.get(opts, :stamp, "run")
    max_streak = Keyword.get(opts, :max_error_streak, 2)
    tiers = Keyword.get(opts, :tiers, [1, 2, 3])

    dir = Path.join("eval/live-runs", stamp)
    File.mkdir_p!(dir)

    p = Personas.named(persona_name)

    # metered surface ONLY: ignition agents spend outside the brain wrap
    Application.put_env(:autopoet, :ignition, false)

    # seed the persona world through the real intake (deterministic lane)
    Autopoet.Profile.clear()
    for {k, v} <- p.profile, do: :ok = Autopoet.Profile.put(k, v)
    File.rm(Autopoet.Intake.marker())

    case Autopoet.Intake.pending_proposal() do
      {stale, _} -> Autopoet.Proposals.reject(stale, "live-tier reseed")
      nil -> :ok
    end

    :ok = Autopoet.Intake.run()
    plan = Autopoet.Intake.parse_plan(Autopoet.Profile.all())

    # clean task premises: the shared body carries prior runs' accepted work —
    # a live brain SEES it and (correctly!) declines duplicate work. Canary run
    # #2 proved it: it found last run's clerk and wrote "(done) already exists"
    # instead of hiring. Each run starts from an un-satisfied premise.
    File.rm(Path.join(Autopoet.Body.root(), "#{plan.workspace.name}/crew.work"))

    case Autopoet.Intake.pending_proposal() do
      _ -> :ok
    end

    for {id, _} <- Autopoet.Proposals.pending(),
        String.starts_with?(Autopoet.Proposals.target_of(id), plan.workspace.name) do
      Autopoet.Proposals.reject(id, "live-run premise reset")
    end

    tasks = Enum.filter(Tasks.all(), &(&1.persona == persona_name and &1.tier in tiers))

    {results, _streak} =
      Enum.reduce(tasks, {[], 0}, fn task, {acc, streak} ->
        if streak >= max_streak do
          IO.puts("  ✋ LIVE #{task.id} — SKIPPED (#{streak} consecutive failures; stopping early for review)")
          {[{task, :halted, %{}} | acc], streak}
        else
          {verdict, telemetry} = run_task(task, plan, dir)
          ok? = verdict == :ok
          IO.puts("  #{if ok?, do: "✓", else: "✗"} LIVE #{task.id} — #{inspect(verdict)} · #{telemetry.ms}ms · #{telemetry.calls} call(s) · ~$#{telemetry.cost}")
          {[{task, verdict, telemetry} | acc], if(ok?, do: 0, else: streak + 1)}
        end
      end)

    results = Enum.reverse(results)
    write_report(dir, persona_name, results)
    summarize(persona_name, results, dir)
  end

  defp run_task(task, plan, dir) do
    {target, change} = task.request.(plan)
    transcript = Path.join(dir, "#{task.id}.md")
    File.write!(transcript, "# LIVE #{task.id}\n\nrequest: `#{target}` — #{change}\n")
    counter = :counters.new(2, [])

    # the live completer: REAL provider (direct OpenRouter — the eval-only
    # allowance; gateway parity when CF_AIG_* is present), fully transcribed
    Application.put_env(:autopoet, :brain_llm, fn prompt ->
      t0 = System.monotonic_time(:millisecond)
      r = Autopoet.Providers.openrouter([%{role: "user", content: prompt}], max_tokens: 3000, temperature: 0.1)
      ms = System.monotonic_time(:millisecond) - t0
      :counters.add(counter, 1, 1)

      {resp, usage} =
        case r do
          {:ok, %{content: c} = m} -> {c, m[:usage] || %{}}
          other -> {inspect(other), %{}}
        end

      cost_microcents = round((usage[:cost] || usage["cost"] || 0.0) * 1_000_000)
      :counters.add(counter, 2, cost_microcents)

      File.write!(
        transcript,
        "\n---\n## round #{:counters.get(counter, 1)} (#{ms}ms · usage #{inspect(usage)})\n\n" <>
          "### prompt (#{byte_size(prompt)}B)\n```\n#{String.slice(prompt, 0, 6000)}\n```\n\n" <>
          "### response\n```\n#{String.slice(to_string(resp), 0, 6000)}\n```\n",
        [:append]
      )

      case r do
        {:ok, %{content: c}} when is_binary(c) -> {:ok, c}
        other -> other
      end
    end)

    t0 = System.monotonic_time(:millisecond)

    verdict =
      try do
        Nexus.Autopoet.Worker.run_once(
          root: Autopoet.Body.root(),
          requests: [%{target: target, change: change}],
          proposer: &Autopoet.Brain.propose/1,
          notify: fn _, _ -> :ok end,
          min_runs: 999_999_999
        )

        case task.artifact.(%{body: Autopoet.Body.root(), plan: plan, report: nil}) do
          :ok -> :ok
          {:fail, r} -> r
        end
      rescue
        e -> {:crashed, Exception.message(e)}
      after
        Application.delete_env(:autopoet, :brain_llm)
      end

    ms = System.monotonic_time(:millisecond) - t0
    cost = :counters.get(counter, 2) / 1_000_000
    File.write!(transcript, "\n---\nverdict: #{inspect(verdict)} · #{ms}ms · ~$#{cost}\n", [:append])
    {verdict, %{ms: ms, calls: :counters.get(counter, 1), cost: Float.round(cost, 5)}}
  end

  defp write_report(dir, persona, results) do
    rows =
      Enum.map_join(results, "\n", fn {t, v, tel} ->
        "| #{t.id} | L#{t.tier} | #{inspect(v)} | #{tel[:ms] || "-"}ms | #{tel[:calls] || 0} | $#{tel[:cost] || 0} |"
      end)

    File.write!(Path.join(dir, "report.md"), """
    # LIVE tier — #{persona} (observational)

    | task | tier | verdict | wall | llm calls | cost |
    |---|---|---|---|---|---|
    #{rows}

    Review ritual: read each transcript; classify failures (missing context /
    format miss / gate refusal / model quality) BEFORE changing anything.
    """)
  end

  defp summarize(persona, results, dir) do
    ok = Enum.count(results, fn {_, v, _} -> v == :ok end)
    cost = results |> Enum.map(fn {_, _, t} -> t[:cost] || 0 end) |> Enum.sum()
    calls = results |> Enum.map(fn {_, _, t} -> t[:calls] || 0 end) |> Enum.sum()

    Autopoet.Eval.History.record("live/#{persona}", %{
      passed: ok,
      total: length(results),
      llm_calls: calls,
      cost_usd: Float.round(cost * 1.0, 5)
    })

    %{persona: persona, passed: ok, total: length(results), cost: cost, calls: calls, dir: dir}
  end
end
