defmodule Autopoet.TaskSuiteEvalTest do
  @moduledoc """
  C3 + B5 (wb-h0tjs.4) — the persona task suites, executed through the REAL
  runtime: request → Worker → Brain (reference solution injected) → body/gate →
  artifact. Fail-to-pass (the artifact) AND pass-to-pass (parse health intact,
  vault untouched, staged persona rules survive appends) per task; failures
  classify by taxonomy so regressions localize. Deterministic by construction
  (scripted reference brain) — one trial IS pass^k here; the stochastic pass^3
  discipline lives in the replay/armlift gates.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{Personas, Tasks}

  test "task suites: 6 personas × 3 tiers through the real runtime, all artifacts land" do
    results =
      for persona <- Tasks.personas() do
        p = Personas.named(persona)

        # seed this persona's world once (shared-home lane, like the persona evals)
        Autopoet.Profile.clear()
        for {k, v} <- p.profile, do: :ok = Autopoet.Profile.put(k, v)
        File.rm(Autopoet.Intake.marker())

        case Autopoet.Intake.pending_proposal() do
          {stale, _} -> Autopoet.Proposals.reject(stale, "task-suite reseed")
          nil -> :ok
        end

        assert :ok = Autopoet.Intake.run()
        plan = Autopoet.Intake.parse_plan(Autopoet.Profile.all())

        # clean crew.work premise: prior persona/L3 runs in the shared test body
        # leave accepted clerks behind, which the outcome grader would count as a
        # pre-existing agent (the shared-test-home fragility eval.iso solves)
        File.rm(Path.join(Autopoet.Body.root(), "#{plan.workspace.name}/crew.work"))

        for task <- Tasks.all(), task.persona == persona do
          {task, run_task(task, plan)}
        end
      end
      |> List.flatten()

    Autopoet.Profile.clear()

    taxonomy = results |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()
    failures = for {t, v} <- results, v != :ok, do: {t.id, v}

    by_tier =
      results
      |> Enum.group_by(fn {t, _} -> t.tier end, fn {_, v} -> v end)
      |> Map.new(fn {tier, vs} -> {tier, "#{Enum.count(vs, &(&1 == :ok))}/#{length(vs)}"} end)

    IO.puts(
      "  ✓ EVAL tasks — #{Enum.count(results, fn {_, v} -> v == :ok end)}/#{length(results)} · " <>
        "L1 #{by_tier[1]} · L2 #{by_tier[2]} · L3 #{by_tier[3]} · taxonomy #{inspect(taxonomy)}"
    )

    Autopoet.Eval.History.record("tasks", %{
      passed: Enum.count(results, fn {_, v} -> v == :ok end),
      total: length(results),
      l1: by_tier[1],
      l2: by_tier[2],
      l3: by_tier[3]
    })

    assert failures == [], "task failures: #{inspect(failures)}"
  end

  defp run_task(task, plan) do
    {target, change} = task.request.(plan)
    reference = task.reference.(plan)

    Application.put_env(:autopoet, :brain_llm, fn _prompt -> {:ok, reference} end)

    vault0 = vault_digest()
    ws = plan.workspace.name
    rules_path = Path.join(Autopoet.Body.root(), "#{ws}/rules.work")
    rules0 = File.read(rules_path)

    report =
      try do
        Nexus.Autopoet.Worker.run_once(
          root: Autopoet.Body.root(),
          requests: [%{target: target, change: change}],
          proposer: &Autopoet.Brain.propose/1,
          notify: fn _, _ -> :ok end,
          min_runs: 999_999_999
        )
      rescue
        _ -> :crashed
      after
        Application.delete_env(:autopoet, :brain_llm)
      end

    cond do
      report == :crashed ->
        :crashed

      # PASS-TO-PASS half 1: the vault never moves during body work (L3's accept
      # targets the body root, so this holds for every tier)
      vault_digest() != vault0 ->
        :vault_violated

      true ->
        ctx = %{body: Autopoet.Body.root(), plan: plan, report: report}

        case task.artifact.(ctx) do
          :ok ->
            # PASS-TO-PASS half 2: appends preserved the staged persona rules
            case {rules0, File.read(rules_path), List.first(plan.rules)} do
              {{:ok, before}, {:ok, now}, first_rule} when is_binary(first_rule) ->
                if not String.contains?(before, first_rule) or String.contains?(now, first_rule),
                  do: :ok,
                  else: :clobbered_rules

              _ ->
                :ok
            end

          {:fail, reason} ->
            reason
        end
    end
  end

  defp vault_digest do
    Path.wildcard(Path.join(Autopoet.Notes.dir(), "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn f -> {f, :erlang.md5(File.read!(f))} end)
  end
end
