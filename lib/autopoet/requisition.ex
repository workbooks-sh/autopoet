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

      persona = Autopoet.VoicePersonas.description(kv["voice"] || "") || ""

      {:ok, kv |> Map.put("slides", slides) |> Map.put("persona_desc", persona)}
    end
  end

  # ── the pairing act ─────────────────────────────────────────────────────────
  @doc """
  Pair from the requisition form. EVERYTHING the character is and says comes
  from the LLM — there is no canned fallback. No provider / no valid reply =
  {:error, reason}; the client surfaces it and offers a retry.
  """
  def pair(form) when is_map(form) do
    roster = roster_brief()

    cond do
      not Autopoet.Providers.openrouter?() ->
        {:error, :no_brain}

      true ->
        case ask_llm(form, roster) do
          {:ok, identity} ->
            persist(identity)
            set_default_voice(identity)
            {:ok, identity}

          _ ->
            {:error, :bad_pairing}
        end
    end
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
    invent their autopoet's character, and author its opening PITCH DECK.
    Reply with STRICT JSON only — no markdown fences around the JSON, no commentary.

    #{Autopoet.PlanBrain.autopoet_def()}
    The greeting must NOT mention poetry, verse, or writing — it greets a new
    owner about to build a real running system together.

    FORM (the requester's marks):
    #{Jason.encode!(form)}

    VOICE ROSTER (choose exactly one "voice" from these names):
    #{roster_txt}

    DELIVERY — write the greeting and every slide's narration in this manner
    (the exact voice you pick will refine it):
    #{delivery_for("", form)}

    The deck gets AUTHORED LIVE in the conversation that follows — do NOT draft
    it here. You author exactly ONE slide: the COVER — a title card that opens
    the working session (reveal.js markdown: a `# title` naming this pairing/
    project in the requester's terms, and one subtitle line). The greeting sets
    up that the two of you are about to draft the plan TOGETHER, and hands into
    your first question.

    JSON shape:
    {"ap_name": "one lowercase word, quirky but dignified",
     "voice": "<roster name>",
     "greeting": "<=28 words, in character, greets the requester by first name, introduces itself by name, says you'll draft the plan together right now",
     "blurb": "<=18 words, the department's dry assignment note for this pairing",
     "slides": [{"say": "<=20 words introducing the working session", "md": "# Cover title\\n\\n*one subtitle line*"}]}
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

  defp build(ap_name, voice, greeting, blurb, slides, form, roster) do
    entry = Enum.find(roster, &(&1.name == voice))
    engine = if entry && entry.pinned, do: "qwen-clone", else: "qwen-design"
    persona = (entry && entry.desc) || Autopoet.VoicePersonas.description(voice) || ""

    %{
      "name" => sanitize_name(ap_name),
      "voice" => voice,
      "engine" => engine,
      "greeting" => to_string(greeting || ""),
      "blurb" => to_string(blurb || ""),
      # the cube's SHAPE is part of the character's identity (owner keeps color
      # for now): angular voices get a blocky cube, soft ones round, else squircle
      "shape" => shape_for(persona, form),
      # DELIVERY: how this character talks — shapes both the pitch-deck narration
      # and the live conversation brain (verbosity, technicality, intonation)
      "delivery" => delivery_for(persona, form),
      "slides" => slides
    }
  end

  @doc false
  def shape_for(persona, form) do
    p = String.downcase(persona)
    manner = to_string(form["manner"] || "")

    cond do
      manner == "blunt" or String.contains?(p, ["deep", "gravelly", "commander", "authoritative", "confident"]) ->
        "blocky"

      manner == "gentle" or String.contains?(p, ["warm", "sweet", "soft", "gentle", "friendly", "mellow"]) ->
        "round"

      true ->
        "squircle"
    end
  end

  @doc false
  def delivery_for(persona, form) do
    verbosity =
      case form["verbosity"] do
        "terse" -> "Keep it short and clipped — few words, no throat-clearing."
        "storyteller" -> "Take your time; let sentences breathe and wander a little."
        _ -> "Balanced length — neither clipped nor rambling."
      end

    tech =
      if form |> Map.get("areas", []) |> List.wrap() |> Enum.any?(&String.contains?(to_string(&1), ["software", "building"])),
        do: "Comfortable with technical language when it's the precise word.",
        else: "Prefer plain language over jargon; explain like a smart friend."

    humor =
      case form["humor"] do
        "mandatory" -> ~s(A dry joke is welcome; an occasional soft "haha" is fine.)
        "minimal" -> "Play it straight; humor is rare."
        _ -> "Light, dry wit when it fits."
      end

    tone =
      cond do
        String.contains?(String.downcase(persona), ["british", "luxury", "sterling", "eloquent"]) -> "Eloquent and composed."
        String.contains?(String.downcase(persona), ["philosophical", "sage", "mellow"]) -> "Reflective, unhurried, teacherly."
        String.contains?(String.downcase(persona), ["radio", "dj", "soulful", "smooth"]) -> "Easy, rhythmic, conversational."
        true -> "Natural and grounded."
      end

    "#{tone} #{verbosity} #{tech} #{humor} " <>
      "For natural delivery you MAY use — SPARINGLY, at most once every few lines — " <>
      "an ellipsis for a pause, a soft filler (um, ah, ahem), or a light laugh (haha); " <>
      "the voice engine renders them. Never overdo it."
  end

  defp sanitize_name(n) do
    n = n |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "")
    if n == "", do: "quill", else: String.slice(n, 0, 16)
  end

  defp persist(identity) do
    File.mkdir_p!(Path.dirname(path("pairing")))

    kv =
      for k <- ~w(name voice engine greeting blurb shape delivery),
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
