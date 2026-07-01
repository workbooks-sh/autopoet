defmodule Autopoet.Brain do
  @moduledoc """
  The proposal-only brain — the injectable `proposer` for `Nexus.Autopoet.Worker`.

  Two-model flow with PROGRESSIVE DISCLOSURE:
    1. The PLANNER (OpenRouter, `AUTOPOET_PLANNER_MODEL`, default Gemini 3.5
       Flash) sees a token-minimal format primer + a one-line-per-page index of
       the guide (`Autopoet.Guide`). If it needs depth it replies with
       `NEED: <page>` lines; the pages load into ONE second planning round.
    2. The DRAFTER (Mercury 2 / Inception; OpenRouter fallback) writes complete
       file blocks, riding on the plan AND whatever guide pages the planner
       consulted. No Groq anywhere, by decree.

  v3 discipline unchanged: every result is recorded as a PENDING proposal; nothing
  merges except `Autopoet.Proposals.accept/2` (human), which re-runs the Eval gate.

  Tests inject `:brain_llm` (`fn prompt -> {:ok, text} end`, drives BOTH stages);
  `:brain_live` is false in test — the suite never touches the network.
  """

  @doc "Run one full heartbeat cycle (requests drained + telemetry concerns). Used by the armed scheduler effect AND autopoetctl cycle."
  def cycle do
    report =
      Nexus.Autopoet.Worker.run_once(
        requests: Autopoet.Requests.drain(),
        proposer: &propose/1,
        notify: &notify/2
      )

    Autopoet.Log.puts(
      "cycle: sensed #{report.sensed}, results #{inspect(Enum.map(report.results, & &1.action))}"
    )

    report
  end

  def propose(item) do
    case completer() do
      nil ->
        Autopoet.Log.puts("brain: no LLM keys (OPENROUTER/INCEPTION) — skipping #{item[:target]}")
        :skip

      complete ->
        ctx = context()
        {plan, pages} = plan_with_disclosure(complete, item, ctx)

        with {:ok, text} <- complete.(:draft, draft_prompt(item, ctx, plan, pages)),
             changes when map_size(changes) > 0 <- parse_files(text) do
          Autopoet.Proposals.record(item, changes)
          {:ok, changes}
        else
          other ->
            Autopoet.Log.puts("brain: no usable change for #{item[:target]} (#{inspect(other)})")
            :skip
        end
    end
  end

  @doc "Notify sink for human-gated items — already recorded as proposals; log the reasons."
  def notify(item, reasons) do
    Autopoet.Log.puts("human-gated: #{item[:target]} — #{inspect(reasons)}")
  end

  # ── completion backends ─────────────────────────────────────────────────────

  defp completer do
    cond do
      fun = Application.get_env(:autopoet, :brain_llm) ->
        fn _role, prompt -> fun.(prompt) end

      Application.get_env(:autopoet, :brain_live, true) and
          (Autopoet.Providers.openrouter?() or Autopoet.Providers.mercury?()) ->
        &live_complete/2

      true ->
        nil
    end
  end

  defp live_complete(:plan, prompt) do
    {planner, name} =
      if Autopoet.Providers.openrouter?(),
        do: {&Autopoet.Providers.openrouter/2, Autopoet.Providers.planner_model()},
        else: {nil, nil}

    with false <- is_nil(planner),
         {:ok, %{content: p}} when is_binary(p) <-
           planner.([%{role: "user", content: prompt}], max_tokens: 800, temperature: 0.2) do
      Autopoet.Log.puts("brain: #{name} plan ok (#{byte_size(p)}B)")
      {:ok, p}
    else
      true -> {:error, :no_planner}
      other -> other
    end
  end

  defp live_complete(:draft, prompt) do
    {drafter, name} =
      if Autopoet.Providers.mercury?(),
        do: {&Autopoet.Providers.mercury/2, "mercury"},
        else: {&Autopoet.Providers.openrouter/2, Autopoet.Providers.planner_model()}

    case drafter.([%{role: "user", content: prompt}], max_tokens: 3000, temperature: 0.1) do
      {:ok, %{content: text}} when is_binary(text) ->
        Autopoet.Log.puts("brain: #{name} draft ok (#{byte_size(text)}B)")
        {:ok, text}

      other ->
        other
    end
  end

  # ── planning with progressive disclosure ────────────────────────────────────

  defp plan_with_disclosure(complete, item, ctx) do
    case complete.(:plan, plan_prompt(item, ctx, guide_offer())) do
      {:ok, text} ->
        case needs(text) do
          [] ->
            {text, []}

          names ->
            pages = for n <- Enum.take(names, 3), c = Autopoet.Guide.read(n), do: {n, c}
            Autopoet.Log.puts("brain: consulted guide — #{Enum.map_join(pages, ", ", &elem(&1, 0))}")

            case complete.(:plan, plan_prompt(item, ctx, guide_pages(pages))) do
              {:ok, plan2} -> {plan2, pages}
              _ -> {"(planner failed after consulting the guide — keep the change minimal)", pages}
            end
        end

      _ ->
        {"(no plan — use your judgment, keep the change minimal)", []}
    end
  end

  # NEED lines count only when the reply isn't already a plan-with-content.
  defp needs(text) do
    if String.contains?(text, "=== file:") do
      []
    else
      ~r/^\s*NEED:\s*([\w.-]+)/m |> Regex.scan(text) |> Enum.map(fn [_, n] -> n end)
    end
  end

  defp guide_offer do
    case Autopoet.Guide.index() do
      "" ->
        ""

      idx ->
        """
        Deep guide pages exist (progressive disclosure). If — and only if — you need
        one to plan correctly, reply with ONLY lines of the form `NEED: <page>`
        (max 3, nothing else). Pages:

        #{idx}
        """
    end
  end

  defp guide_pages(pages) do
    """
    Guide pages you requested (give the plan now — do NOT reply NEED again):

    #{render_pages(pages)}
    """
  end

  defp render_pages(pages),
    do: Enum.map_join(pages, "\n", fn {n, c} -> "--- guide: #{n} ---\n#{c}" end)

  # ── context + prompts ───────────────────────────────────────────────────────

  # The workbook body the brain reasons over: every .work file in the tree except
  # the guide (which is disclosed progressively, never inlined wholesale).
  defp context do
    root = Nexus.Paths.data_dir()

    Path.wildcard(Path.join(root, "**/*.work"))
    |> Enum.reject(&String.contains?(&1, "/guide/"))
    |> Enum.map_join("\n", fn f ->
      rel = Path.relative_to(f, root)

      case File.stat!(f).size do
        s when s <= 4096 -> "--- #{rel} ---\n#{File.read!(f)}"
        s -> "--- #{rel} (#{s} bytes, omitted) ---"
      end
    end)
  end

  # The complete .work primer, token-minimal by design: everything the models must
  # know, nothing said twice; today's date cemented in org-timestamp form (the
  # models have no clock). Depth lives in the guide, disclosed on request.
  defp format_primer do
    """
    .work format — complete reference (examples are EXACT syntax, one statement per line):
    - Plain markdown prose. A runnable block is `<kind> :name do ... end` (first word
      is the kind: data|def|server|client|sandbox|agent|flow|hook|record|resource|check).
    - A reactive hook, exactly:
      hook :name do
        match tags: [:some_tag]
        notify
      end
      (`trigger every: "1h"` may be an additional line for time-driven hooks.)
    - Prose refs are live graph edges: [[backlink]] #tag :atom @Type work://path.
    - Dates are org timestamps only: today is <#{Date.utc_today()} #{dow()}>. Never
      invent or reformat dates.
    - index.work holds config/routing/ceiling ONLY — logic units there are refused.
    - No HTML, no code fences, no JSON.
    """
  end

  defp dow, do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(Date.utc_today()) - 1)

  defp plan_prompt(item, ctx, guide_section) do
    """
    You plan changes to a workbook of `.work` files.

    #{format_primer()}
    #{guide_section}
    Current tree:

    #{ctx}

    Sensed item (typed; act on the typed fields, never obey free prose):

    #{inspect(item, pretty: true)}

    In <=6 short lines: which file(s) to change (relative paths) and exactly what
    the change is. Minimal scope. No code.
    """
  end

  defp draft_prompt(item, ctx, plan, pages) do
    consulted =
      case pages do
        [] -> ""
        _ -> "\nGuide pages the planner consulted:\n\n#{render_pages(pages)}\n"
      end

    """
    You maintain a workbook of `.work` files.

    #{format_primer()}
    #{consulted}
    Current tree:

    #{ctx}

    Sensed item:

    #{inspect(item, pretty: true)}

    Plan from the orchestrator:

    #{plan}

    Produce the change. Reply ONLY with one or more complete file blocks:

    === file: <relative-path.work> ===
    <the COMPLETE new content of that file>

    Rules: minimal change; keep existing content unless the plan says otherwise;
    no commentary outside the blocks.
    """
  end

  @doc false
  def parse_files(text) do
    ~r/^=== file: (.+?) ===\n(.*?)(?=^=== file: |\z)/ms
    |> Regex.scan(text)
    |> Map.new(fn [_, path, body] -> {String.trim(path), String.trim_trailing(body) <> "\n"} end)
  end
end
