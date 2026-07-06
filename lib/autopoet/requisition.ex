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

      steps =
        case File.read(path("pairing-steps")) do
          {:ok, s} ->
            for line <- String.split(s, "\n", trim: true) do
              case String.split(line, "|", parts: 3) do
                [say, reveal, point] ->
                  %{
                    say: String.trim(say),
                    reveal: reveal |> String.trim() |> String.split(",", trim: true),
                    point: point |> String.trim()
                  }

                _ ->
                  %{say: String.trim(line), reveal: [], point: ""}
              end
            end

          _ ->
            []
        end

      d2 =
        case File.read(path("pairing.d2")) do
          {:ok, src} -> src
          _ -> ""
        end

      {:ok, Map.merge(kv, %{"steps" => steps, "d2" => d2})}
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
    AP-7 (personality requisition). Pair them with ONE voice from the roster
    and invent their autopoet's character. Reply with STRICT JSON only — no
    markdown fences, no commentary.

    FORM (the requester's marks):
    #{Jason.encode!(form)}

    VOICE ROSTER (choose exactly one "voice" from these names):
    #{roster_txt}

    Also author the intro the autopoet performs on its whiteboard: a D2
    diagram (simple ids, `a -> b: label` edges, at most 9 nodes, shaped by
    the requester's marks — their deployment areas become the build nodes)
    plus exactly 4 narration steps that progressively reveal it. Every id in
    "reveal" must be an edge that appears in the d2 source, written as
    "a->b". "point" must be a node id from the d2.

    JSON shape:
    {"ap_name": "one lowercase word, quirky but dignified",
     "voice": "<roster name>",
     "greeting": "<=25 words, in character, greets the requester by first name, introduces itself by name",
     "blurb": "<=18 words, the department's dry assignment note for this pairing",
     "d2": "<d2 source, \\n separated>",
     "steps": [{"say": "<=28 words", "reveal": ["a->b"], "point": "b"}, ...]}
    """

    with {:ok, %{content: content}} <-
           Autopoet.Providers.openrouter([%{role: "user", content: prompt}],
             max_tokens: 1400,
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
    d2 = raw["d2"] || ""

    steps =
      for s <- List.wrap(raw["steps"]),
          is_binary(s["say"]) and s["say"] != "" do
        reveal =
          for e <- List.wrap(s["reveal"]),
              is_binary(e),
              edge_in_d2?(e, d2),
              do: e

        %{say: s["say"], reveal: reveal, point: to_string(s["point"] || "")}
      end

    cond do
      not MapSet.member?(names, voice) -> :error
      d2 == "" or steps == [] -> :error
      true -> {:ok, build(raw["ap_name"], voice, raw["greeting"], raw["blurb"], d2, steps, form, roster)}
    end
  end

  defp edge_in_d2?(edge, d2) do
    case String.split(edge, "->", parts: 2) do
      [a, b] -> Regex.match?(~r/#{Regex.escape(String.trim(a))}\s*->\s*#{Regex.escape(String.trim(b))}/, d2)
      _ -> false
    end
  end

  # deterministic pairing — the onboarding never blocks on a provider
  defp fallback(form, roster) do
    first = form |> Map.get("name", "") |> to_string() |> String.split(" ") |> List.first() |> to_string()
    areas = form |> Map.get("areas", []) |> List.wrap() |> Enum.take(3)

    build_nodes =
      areas
      |> Enum.with_index()
      |> Enum.map(fn {a, i} -> {"b#{i}", to_string(a)} end)

    d2 =
      """
      you: #{if first == "", do: "you", else: first}
      ap: your autopoet
      mission: your mission
      #{Enum.map_join(build_nodes, "\n", fn {id, label} -> "#{id}: #{label}" end)}
      you -> ap: works with
      ap -> mission: serves
      #{Enum.map_join(build_nodes, "\n", fn {id, _} -> "ap -> #{id}: weaves" end)}
      """

    steps =
      [
        %{say: "everything starts with the two of us.", reveal: ["you->ap"], point: "ap"},
        %{say: "and hangs off a mission — yours, in your words.", reveal: ["ap->mission"], point: "mission"}
      ] ++
        Enum.map(build_nodes, fn {id, label} ->
          %{say: "you marked #{label} — so that's where i'll weave first.", reveal: ["ap->#{id}"], point: id}
        end)

    voice = if Enum.any?(roster, &(&1.name == "rosalind")), do: "rosalind", else: List.first(roster).name

    build(
      "quill",
      voice,
      "hi#{if first != "", do: " " <> String.downcase(first)} — i'm quill, your autopoet. the department matched us. let me show you how this works.",
      "requisition approved. pairing: standard-issue poet, above-average curiosity.",
      d2,
      steps,
      form,
      roster
    )
  end

  defp build(ap_name, voice, greeting, blurb, d2, steps, _form, roster) do
    entry = Enum.find(roster, &(&1.name == voice))
    engine = if entry && entry.pinned, do: "qwen-clone", else: "qwen-design"

    %{
      "name" => sanitize_name(ap_name),
      "voice" => voice,
      "engine" => engine,
      "greeting" => to_string(greeting || ""),
      "blurb" => to_string(blurb || ""),
      "d2" => d2,
      "steps" => steps
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
    File.write!(path("pairing.d2"), identity["d2"])

    steps_txt =
      Enum.map_join(identity["steps"], "\n", fn s ->
        "#{String.replace(s.say, "|", "/")} | #{Enum.join(s.reveal, ",")} | #{s.point}"
      end)

    File.write!(path("pairing-steps"), steps_txt <> "\n")
  end

  # the paired voice IS the default voice from here on — every bare synth
  # speaks as the character the department assigned
  defp set_default_voice(identity) do
    File.mkdir_p!(Path.join([home(), "data", "voices"]))
    File.write!(Path.join([home(), "data", "voices", "default"]), "#{identity["engine"]} #{identity["voice"]}\n")
  end
end
