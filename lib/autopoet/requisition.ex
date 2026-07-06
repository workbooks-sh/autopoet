defmodule Autopoet.Requisition do
  @moduledoc """
  The AUTOPOET DEPARTMENT requisition desk — pairs a new owner with their
  autopoet from the intake form (name + marks), via the planner LLM.

  The pairing is the onboarding's first real act: the form answers go to the
  LLM together with the ACCEPTED voice roster (names, persona descriptions,
  blind-listen traits, accents), and it returns the character — a name, a
  voice, a greeting, an in-world assignment note, and a custom D2 intro
  diagram with narration steps. Everything is validated hard; a deterministic
  pairing ships when no LLM is configured (onboarding never blocks).

  Persistence is plain text under data/ (no JSON sidecars):
    data/pairing        — "key value" lines (name/voice/engine/blurb/greeting)
    data/pairing.d2     — the intro diagram source
    data/pairing-steps  — one step per line: say | edge,edge | point
  """

  defp home, do: Autopoet.Discovery.home()
  defp path(f), do: Path.join([home(), "data", f])

  # ── read back (for /onboard/pairing.json and plan mode) ────────────────────
  def pairing do
    with {:ok, body} <- File.read(path("pairing")) do
      kv =
        for line <- String.split(body, "\n", trim: true),
            [k, v] <- [String.split(line, " ", parts: 2)],
            into: %{},
            do: {k, v}

      says =
        case File.read(path("pairing-says")) do
          {:ok, s} -> String.split(s, "\n", trim: true)
          _ -> []
        end

      mds =
        case File.read(path("pairing-deck.md")) do
          {:ok, deck} -> deck |> String.split(~r/\n\s*---\s*\n/, trim: true) |> Enum.map(&String.trim/1)
          _ -> []
        end

      slides =
        says
        |> Enum.zip(mds)
        |> Enum.map(fn {say, md} -> %{"say" => say, "md" => md} end)

      {:ok, Map.put(kv, "slides", slides)}
    end
  end

  # ── the pairing act ─────────────────────────────────────────────────────────
  @doc "Pair from the requisition form. Returns {:ok, map} always (fallback inside)."
  def pair(form) when is_map(form) do
    roster = roster_brief()

    result =
      if Autopoet.Providers.openrouter?() do
        case ask_llm(form, roster) do
          {:ok, identity} -> identity
          _ -> fallback(form, roster)
        end
      else
        fallback(form, roster)
      end

    persist(result)
    set_default_voice(result)
    {:ok, result}
  end

  defp roster_brief do
    pinned = Autopoet.VoiceRoster.pinned()
    verdicts = Autopoet.VoiceRoster.verdicts()

    for name <- Enum.uniq(Autopoet.VoicePersonas.names() ++ pinned),
        verdicts[name] != "rejected",
        t = Autopoet.VoiceRoster.traits(name),
        t != nil do
      %{
        name: name,
        pinned: name in pinned,
        desc: Autopoet.VoicePersonas.description(name) || "",
        accent: Autopoet.VoiceRoster.accents()[name] || "",
        traits: t
      }
    end
  end

  defp ask_llm(form, roster) do
    roster_txt =
      Enum.map_join(roster, "\n", fn v ->
        "- #{v.name}: #{v.desc} accent=#{v.accent} traits=#{inspect(Map.drop(v.traits, ["kind"]))}"
      end)

    prompt = """
    You are the AUTOPOET DEPARTMENT's pairing officer. A requester filed form
    AP-7 (personality requisition). Pair them with ONE voice from the roster,
    invent their autopoet's character, and author its opening PITCH DECK —
    reveal.js markdown slides the autopoet presents while introducing itself.
    Reply with STRICT JSON only — no markdown fences around the JSON, no commentary.

    FORM (the requester's marks):
    #{Jason.encode!(form)}

    VOICE ROSTER (choose exactly one "voice" from these names):
    #{roster_txt}

    THE DECK is how the autopoet shows what it understands and what it will do,
    built ENTIRELY from the requester's marks — this is emergent, so every slide
    reflects THEIR answers, not a template. Author 3 to 5 slides. Each slide is
    reveal.js markdown (use `# Title`, `## Subhead`, `- bullets`). ONE slide
    SHOULD contain a mermaid diagram of the plan as a fenced block:
    ```mermaid
    flowchart LR
      you[you] --> ap[your autopoet] --> ship[what ships]
    ```
    Keep slides tight — a title and 2 to 4 bullets, or the diagram. Each slide
    pairs with a `say`: <=30 words of narration the autopoet speaks over it.

    JSON shape:
    {"ap_name": "one lowercase word, quirky but dignified",
     "voice": "<roster name>",
     "greeting": "<=25 words, in character, greets the requester by first name, introduces itself by name, says it drew up a plan",
     "blurb": "<=18 words, the department's dry assignment note for this pairing",
     "slides": [{"say": "<=30 words of narration", "md": "# Slide title\\n\\n- point one\\n- point two"}, ...]}
    """

    with {:ok, %{content: content}} <-
           Autopoet.Providers.openrouter([%{role: "user", content: prompt}],
             max_tokens: 1800,
             temperature: 0.6
           ),
         {:ok, raw} <- Jason.decode(strip_fences(content)),
         {:ok, identity} <- validate(raw, form, roster) do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  defp strip_fences(s) do
    s
    |> String.replace(~r/^\s*```(?:json)?/m, "")
    |> String.replace(~r/```\s*$/m, "")
    |> String.trim()
  end

  defp validate(raw, form, roster) do
    names = MapSet.new(roster, & &1.name)
    voice = raw["voice"]

    slides =
      for s <- List.wrap(raw["slides"]),
          is_binary(s["say"]) and s["say"] != "",
          is_binary(s["md"]) and String.trim(s["md"]) != "" do
        %{say: s["say"], md: s["md"]}
      end

    cond do
      not MapSet.member?(names, voice) -> :error
      slides == [] -> :error
      true -> {:ok, build(raw["ap_name"], voice, raw["greeting"], raw["blurb"], slides, form, roster)}
    end
  end

  # deterministic pairing — the onboarding never blocks on a provider
  defp fallback(form, roster) do
    first = form |> Map.get("name", "") |> to_string() |> String.split(" ") |> List.first() |> to_string()
    who = if first == "", do: "you", else: first
    areas = form |> Map.get("areas", []) |> List.wrap() |> Enum.take(4)
    area_bullets = if areas == [], do: "- whatever you bring me", else: Enum.map_join(areas, "\n", &"- #{&1}")
    flow_nodes = if areas == [], do: "ap --> work[your work]", else: Enum.map_join(Enum.with_index(areas), "\n  ", fn {a, i} -> "ap --> n#{i}[#{a}]" end)

    slides = [
      %{
        say: "here's the shape of what we're doing together.",
        md: "# the plan\n\n- you bring the words\n- i weave the system\n- it ships, and wakes up every morning"
      },
      %{
        say: "you told the department where to point me — so that's where we start.",
        md: "## where i'll weave first\n\n#{area_bullets}"
      },
      %{
        say: "and here's how the pieces connect. this diagram grows as we talk.",
        md: "## how it fits\n\n```mermaid\nflowchart LR\n  you[#{who}] --> ap[your autopoet]\n  #{flow_nodes}\n```"
      }
    ]

    voice = if Enum.any?(roster, &(&1.name == "rosalind")), do: "rosalind", else: List.first(roster).name

    build(
      "quill",
      voice,
      "hi#{if first != "", do: " " <> String.downcase(first)} — i'm quill, your autopoet. the department matched us, and i already sketched a plan.",
      "requisition approved. pairing: standard-issue poet, above-average curiosity.",
      slides,
      form,
      roster
    )
  end

  defp build(ap_name, voice, greeting, blurb, slides, _form, roster) do
    entry = Enum.find(roster, &(&1.name == voice))
    engine = if entry && entry.pinned, do: "qwen-clone", else: "qwen-design"

    %{
      "name" => sanitize_name(ap_name),
      "voice" => voice,
      "engine" => engine,
      "greeting" => to_string(greeting || ""),
      "blurb" => to_string(blurb || ""),
      "slides" => slides
    }
  end

  defp sanitize_name(n) do
    n = n |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "")
    if n == "", do: "quill", else: String.slice(n, 0, 16)
  end

  defp persist(identity) do
    File.mkdir_p!(Path.dirname(path("pairing")))

    kv =
      for k <- ~w(name voice engine greeting blurb),
          do: "#{k} #{String.replace(identity[k] || "", "\n", " ")}"

    File.write!(path("pairing"), Enum.join(kv, "\n") <> "\n")

    # slides persist as the pitch deck markdown, one slide per reveal.js
    # separator — this file IS the plan artifact (the "inform 7" the agent
    # later compiles toward the .work). A parallel index keeps the narration.
    deck_md =
      identity["slides"]
      |> Enum.map(& &1.md)
      |> Enum.join("\n\n---\n\n")

    File.write!(path("pairing-deck.md"), deck_md <> "\n")

    says = Enum.map_join(identity["slides"], "\n", fn s -> String.replace(s.say, "\n", " ") end)
    File.write!(path("pairing-says"), says <> "\n")
  end

  # the paired voice IS the default voice from here on — every bare synth
  # speaks as the character the department assigned
  defp set_default_voice(identity) do
    File.mkdir_p!(Path.join([home(), "data", "voices"]))
    File.write!(Path.join([home(), "data", "voices", "default"]), "#{identity["engine"]} #{identity["voice"]}\n")
  end
end
