defmodule Autopoet.PlanCompile do
  @moduledoc """
  THE MISSING SEAM — "inform 7 → inform 6". The onboarding conversation authors
  a pitch DECK (reveal.js markdown, human-readable); `Autopoet.Intake` builds
  the first vault from a `plan.*` CONTRACT in the profile. Nothing bridged them,
  so the deck was decorative and the vault came out generic.

  This compiles the finished deck (+ pairing + form) into that contract:
    plan.workspace : "Title — page, page, page"
    plan.agent.1-4 : "Name — standing job"
    plan.rule.1-5  : "rule text"
    plan.setting   : one policy line
    plan.connect   : "provider, provider"   (only integrations the deck names)
    plan.firstrun  : the first concrete task
  written to `Autopoet.Profile`, so `Intake.run` produces a vault that actually
  reflects what the human and their autopoet planned together.

  LLM-driven (the deck is prose); a deterministic fallback keeps onboarding
  whole when no provider is configured.
  """

  @doc """
  Compile the deck into the plan.* contract and WRITE it to the profile.
  Returns {:ok, plan_map} — the same shape `Intake.parse_plan` reads back.
  """
  def from_deck(deck_md, pairing \\ %{}, form \\ %{}) do
    plan =
      # any live lane — the fast conversational provider (Cerebras, via the
      # Workbooks CF AI Gateway when configured) OR the planner. GOAL: all
      # traffic through the gateway; Providers.openrouter already routes through
      # it when CF_AIG_URL/TOKEN are set, so this needs no change to get there.
      if Autopoet.VoiceBrain.available?() or Autopoet.Providers.openrouter?() do
        case ask_llm(deck_md, pairing, form) do
          {:ok, p} -> p
          _ -> fallback(deck_md, form)
        end
      else
        fallback(deck_md, form)
      end

    write_profile(plan, form)
    {:ok, plan}
  end

  # laddered completion: fast lane first (Cerebras via the gateway), planner
  # fallback — same posture as Autopoet.PlanBrain
  defp complete(messages) do
    fast =
      if Autopoet.VoiceBrain.available?() do
        case Autopoet.VoiceBrain.complete(messages, max_tokens: 1600, temperature: 0.3) do
          {:ok, %{content: c}} -> {:ok, c}
          {:ok, c} when is_binary(c) -> {:ok, c}
          _ -> :error
        end
      else
        :error
      end

    with :error <- fast do
      case Autopoet.Providers.openrouter(messages, max_tokens: 1600, temperature: 0.3) do
        {:ok, %{content: c}} -> {:ok, c}
        _ -> :error
      end
    end
  end

  defp ask_llm(deck_md, pairing, form) do
    prompt = """
    You are a build compiler. A person and their AI companion just finished a
    planning session; the PITCH DECK below is the plan. Compile it into a strict
    build spec for the vault generator. Extract ONLY what the deck actually says
    — never invent scope the human didn't agree to.

    #{Autopoet.PlanBrain.autopoet_def()}
    So pages/agents/firstrun describe SOFTWARE + automations, never poetry.

    THE PERSON (form marks): #{Jason.encode!(form)}
    THE PAIRED COMPANION: #{pairing["name"]} (#{pairing["persona_desc"]})

    THE DECK (markdown slides, separated by ---):
    #{String.slice(deck_md || "", 0, 6000)}

    Requirements: workspace_title is 2-4 words. pages is 3-6 short section
    names (the real parts of their system). agents is 1-3 real roles the deck
    implies, each a one-word name + a SHORT standing job (max 12 words). rules is 0-4
    plain-language automations the deck describes. setting is one sentence on
    how the agents behave (from the deck's tone). connect lists ONLY
    integrations the deck explicitly names (e.g. instagram, github), else [].
    firstrun is the single first concrete task from the deck's first deliverable.

    Reply with STRICT JSON ONLY — no comments, no code fences, no prose:
    {"workspace_title":"","pages":[""],"agents":[{"name":"","job":""}],"rules":[],"setting":"","connect":[],"firstrun":""}
    """

    case complete([%{"role" => "user", "content" => prompt}]) do
      {:ok, content} ->
        case decode(content) do
          {:ok, raw} ->
            case validate(raw) do
              {:ok, plan} -> {:ok, plan}
              :error -> Autopoet.Log.puts("plan_compile: VALIDATE miss — #{inspect(Map.take(raw, ["workspace_title", "agents"]))}"); :error
            end

          :error ->
            Autopoet.Log.puts("plan_compile: DECODE miss — #{String.slice(content, 0, 250)}")
            :error
        end

      other ->
        Autopoet.Log.puts("plan_compile: no completion (#{inspect(other)})")
        :error
    end
  end

  defp validate(raw) do
    title = clean(raw["workspace_title"] || "")
    pages = list(raw["pages"]) |> Enum.take(6)
    # iterate the RAW agent maps — NOT list/1, which cleans each element to a
    # string (a map → "") and would drop every agent
    agents =
      for a <- List.wrap(raw["agents"]),
          is_map(a),
          n = clean(a["name"]),
          n != "",
          j = clean(a["job"]),
          j != "" do
        %{name: n, job: j}
      end
      |> Enum.take(3)

    cond do
      title == "" or pages == [] or agents == [] ->
        :error

      true ->
        {:ok,
         %{
           title: title,
           pages: pages,
           agents: agents,
           rules: list(raw["rules"]) |> Enum.take(4),
           setting: clean(raw["setting"] || ""),
           connect: list(raw["connect"]) |> Enum.take(4),
           firstrun: clean(raw["firstrun"] || "")
         }}
    end
  end

  # deterministic: derive a plausible plan from the deck headings + form
  defp fallback(deck_md, form) do
    headings =
      (deck_md || "")
      |> String.split("\n")
      |> Enum.filter(&String.match?(&1, ~r/^#+\s/))
      |> Enum.map(&(&1 |> String.replace(~r/^#+\s*/, "") |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    first = form |> Map.get("name", "") |> to_string() |> String.split(" ") |> List.first()
    _areas = form |> Map.get("areas", []) |> List.wrap()

    %{
      title: List.first(headings) || "#{first || "Your"} Workspace",
      pages: (Enum.drop(headings, 1) |> Enum.take(5)) |> then(&(if &1 == [], do: ["overview", "work", "notes"], else: &1)),
      agents: [%{name: "steward", job: "keep the workspace current and do the first honest pass of the plan"}],
      rules: [],
      setting: "Act in plain steps, keep receipts, ask before anything irreversible.",
      connect: [],   # integrations come from the deck (LLM), never from area names
      firstrun: "Read the plan and set up the first page of the workspace."
    }
  end

  # write the plan.* contract Intake.parse_plan reads
  defp write_profile(plan, form) do
    put("plan.workspace", "#{plan.title} — #{Enum.join(plan.pages, ", ")}")

    plan.agents
    |> Enum.with_index(1)
    |> Enum.each(fn {a, n} -> put("plan.agent.#{n}", "#{a.name} — #{a.job}") end)

    plan.rules
    |> Enum.with_index(1)
    |> Enum.each(fn {r, n} -> put("plan.rule.#{n}", to_string(r)) end)

    if plan.setting != "", do: put("plan.setting", plan.setting)
    if plan.connect != [], do: put("plan.connect", Enum.join(plan.connect, ", "))
    if plan.firstrun != "", do: put("plan.firstrun", plan.firstrun)

    # carry the human's identity + intent so the genome/briefing personalize.
    # intent MUST be one of Intake.genome_key's keys (money|build|productivity|
    # delegate) or the vault falls back to the blank genome (generic pages)
    if (name = form["name"]) && name != "", do: put("owner", to_string(name))
    put("intent", intent_of(form))
    if (ind = form["remarks"]) && to_string(ind) != "", do: put("industry", to_string(ind))
  end

  defp intent_of(form) do
    areas = form |> Map.get("areas", []) |> List.wrap() |> Enum.map(&to_string/1) |> Enum.join(" ") |> String.downcase()

    cond do
      String.contains?(areas, "business") -> "money"
      String.contains?(areas, ["software", "building"]) -> "build"
      String.contains?(areas, "mischief") -> "build"
      String.contains?(areas, "delegat") -> "delegate"
      true -> "productivity"
    end
  end

  defp put(k, v), do: Autopoet.Profile.put(k, to_string(v))

  defp list(v) when is_list(v), do: Enum.map(v, &clean/1) |> Enum.reject(&(&1 == "" or is_nil(&1)))
  defp list(_), do: []

  defp clean(nil), do: ""
  defp clean(m) when is_map(m), do: ""
  defp clean(s), do: s |> to_string() |> String.replace("\n", " ") |> String.trim()

  defp decode(content) do
    s =
      content
      |> String.replace(~r/^\s*```(?:json)?/m, "")
      |> String.replace(~r/```\s*$/m, "")
      |> String.trim()

    case Jason.decode(s) do
      {:ok, m} when is_map(m) ->
        {:ok, m}

      _ ->
        with {start, _} <- :binary.match(s, "{"),
             [_ | _] = ends <- :binary.matches(s, "}"),
             {stop, _} <- List.last(ends),
             true <- stop >= start,
             {:ok, m} <- Jason.decode(binary_part(s, start, stop - start + 1)) do
          {:ok, m}
        else
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end
end
