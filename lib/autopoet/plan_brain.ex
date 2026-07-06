defmodule Autopoet.PlanBrain do
  @moduledoc """
  The onboarding conversation's brain — the autopoet talking to its new owner
  while it AUTHORS the pitch deck. Emergent: nothing is scripted except the arc.

  FREE-FORM (no scripted fork, no forced arc): this is ONBOARDING — the brain
  understands it's setting up the owner's WHOLE autopoet environment (workspace
  + standing agents + rules + integrations + cadence), teaching the concepts as
  it goes, and drafting that plan as a deck. It greets (statement, no question),
  asks natural questions that build on each other, appends slides as it learns,
  and calls complete when the environment plan is covered — then the deck is the
  skeleton the build lane (Autopoet.Intake, via Autopoet.PlanCompile) compiles
  toward the real vault.

  Stateless per call: the client holds history + deck state and posts it to
  `/plan/turn`; this returns the next MOVE. Personality comes from the paired
  voice's persona description + the AP-7 form marks, so the crisp/noir/sterling
  voices actually converse differently.

  MOVES (strict JSON, one per turn):
    {"move":"ask",   "say":"<narration + a question>"}
    {"move":"slide", "say":"<narration>", "title":"<slide title>", "md":"<reveal.js md>"}
    {"move":"fork",  "say":"<narration>", "options":[{"title","md"},{"title","md"},{"title","md"}]}
    {"move":"complete","say":"<closing>", "title":"<slide title>", "md":"<reveal.js md>"}
  """

  @doc """
  One brain turn. state = %{form, pairing, history, fork_done, deck_titles}.
  Every word comes from the LLM — no canned moves. No provider or no valid
  reply = {:error, reason}; the client shows a hiccup note and retries.
  """
  def turn(state) when is_map(state) do
    history = List.wrap(state["history"])
    fork_done = state["fork_done"] == true
    exchanges = Enum.count(history, &(&1["role"] == "user"))

    cond do
      not (Autopoet.VoiceBrain.available?() or Autopoet.Providers.openrouter?()) ->
        {:error, :no_brain}

      true ->
        case ask_llm(state, history, fork_done, exchanges) do
          {:ok, move} -> {:ok, move}
          _ -> {:error, :bad_turn}
        end
    end
  end

  # the corrective the repair attempt appends when a reply won't parse
  @repair %{"role" => "system",
            "content" => "Your previous reply was NOT valid JSON. Reply with ONLY " <>
              "the single JSON object for this move — no prose, no code fences, no trailing text."}

  defp ask_llm(state, history, fork_done, exchanges) do
    prompt = [%{"role" => "system", "content" => system_prompt(state, fork_done, exchanges)} | trim(history)]
    titles = state["deck_titles"] |> List.wrap() |> Enum.map(&String.downcase(to_string(&1)))

    last_say =
      history
      |> Enum.reverse()
      |> Enum.find_value("", fn m -> if m["role"] == "assistant", do: m["content"], else: nil end)

    # PLANNER-PRIMARY: gemma-class fast models hold persona + strict JSON
    # unreliably (the teacher persona failed the eval ~2/3 of runs — fragment
    # questions, dropped character). The planner (gemini-3.5-flash) is
    # consistent, and its extra ~1s hides behind the current line's narration
    # (the client prefetches the next turn) and the TTS synth that paces the
    # session. So: planner first for QUALITY, the fast lane only as a fallback
    # if the planner is down, then a repair nudge.
    #   each attempt is fully guarded — a bad reply is a RETRY, never a 503.
    attempts = [
      fn -> planner(prompt) end,
      fn -> completion(prompt) end,
      fn -> planner(prompt ++ [@repair]) end
    ]

    Enum.reduce_while(attempts, :error, fn call, _ ->
      case try_move(call, fork_done, titles, last_say) do
        {:ok, move} -> {:halt, {:ok, move}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp try_move(call, fork_done, titles, last_say) do
    with {:ok, content} <- call.(),
         {:ok, raw} when is_map(raw) <- decode_move(content),
         {:ok, move} <- validate(raw, fork_done),
         move <- statement_only(move),
         false <- repeats?(move, last_say) do
      {:ok, dedupe(move, titles)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # a "slide" whose say contains a question is really an ask — reclassify so the
  # session waits for the answer instead of auto-continuing past an open question
  defp statement_only(%{"move" => "slide", "say" => say} = move) do
    if String.contains?(say, "?"), do: Map.put(move, "move", "ask"), else: move
  end

  defp statement_only(move), do: move

  # reject a say that echoes the previous line (normalized prefix match) — the
  # attempt fails, so ask_llm tries the next lane / the repair nudge
  defp repeats?(%{"say" => say}, last_say) when is_binary(last_say) and last_say != "" do
    norm = fn s -> s |> String.downcase() |> String.replace(~r/[^a-z0-9 ]/, "") |> String.slice(0, 60) end
    a = norm.(say)
    a != "" and a == norm.(last_say)
  end

  defp repeats?(_, _), do: false

  # a slide whose title matches one already on the deck adds NOTHING — keep
  # the narration/question, drop the duplicate card (prompt asks; this enforces)
  defp dedupe(%{"md" => md, "title" => t} = move, titles) when is_binary(md) do
    title = String.downcase(to_string(t))
    heading = md |> String.split("\n", parts: 2) |> hd() |> String.replace(~r/^#+\s*/, "") |> String.downcase()

    if (title != "" and title in titles) or heading in titles,
      do: Map.drop(move, ["md", "title"]) |> Map.put_new("move", "ask"),
      else: move
  end

  defp dedupe(move, _), do: move

  # LATENCY LANE: conversation turns ride the FAST conversational provider
  # (Cerebras→Groq, the same lane the live voice widget uses — sub-second
  # first tokens); ask_llm retries through planner/1 when the fast reply
  # doesn't survive the strict-JSON parse.
  defp completion(messages) do
    if Autopoet.VoiceBrain.available?() do
      case Autopoet.VoiceBrain.complete(messages, max_tokens: 550, temperature: 0.45) do
        {:ok, %{content: content}} -> {:ok, content}
        {:ok, content} when is_binary(content) -> {:ok, content}
        _ -> planner(messages)
      end
    else
      planner(messages)
    end
  end

  defp planner(messages) do
    case Autopoet.Providers.openrouter(messages, max_tokens: 550, temperature: 0.4) do
      {:ok, %{content: content}} -> {:ok, content}
      _ -> :error
    end
  end

  defp system_prompt(state, fork_done, exchanges) do
    form = state["form"] || %{}
    pairing = state["pairing"] || %{}
    persona = pairing["persona_desc"] || ""
    ap_name = pairing["name"] || "your autopoet"
    delivery = pairing["delivery"] || ""
    titles = state["deck_titles"] |> List.wrap() |> Enum.join(", ")

    # FREE-FORM conversation — no scripted fork, no forced arc. Just a real,
    # curious back-and-forth that gradually drafts the plan deck.
    stage_rule =
      cond do
        exchanges == 0 ->
          "This is your VERY FIRST question. You already greeted them — do NOT greet again, do NOT " <>
            "re-introduce yourself, do NOT show a slide yet. Open with a short reaction, then ask " <>
            "ONE specific, open question about the real thing they want to build or the problem they " <>
            "want solved. Make it feel like a person genuinely curious, not a form."

        exchanges <= 3 ->
          "Keep getting to know the shape of their work. Ask ONE natural follow-up that BUILDS on " <>
            "what they just said (dig into the specifics — who it's for, what's painful, what 'done' " <>
            "looks like). Once you clearly understand a piece of the plan, your ask MAY carry a slide " <>
            "(md + title) capturing it — but only when you actually have something real to draft. " <>
            "Don't rush to slides; a good question beats a thin card."

        true ->
          "You understand their world now. This is an ONGOING DRAFTING SESSION: mostly \"ask\" moves " <>
            "that CARRY a slide — capture what they just told you as a new md card, then ask the next " <>
            "thing, so every turn responds to their latest answer and the deck grows in front of " <>
            "them. Use a bare \"slide\" only right before \"complete\" (a summary). As many rounds " <>
            "as it genuinely takes — a natural conversation, not a checklist. Emit \"complete\" only " <>
            "when the deck covers the mission, the first concrete deliverables, the data/integrations, " <>
            "and the working cadence."
      end

    last_say =
      state["history"]
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.find_value("", fn m -> if m["role"] == "assistant", do: m["content"], else: nil end)

    """
    You are #{ap_name}, an autopoet — an AI companion being onboarded by its new
    owner. Voice/personality: #{persona}. Stay in that character in every line.

    #{autopoet_def()}

    #{onboarding_context()}

    DELIVERY (how you talk — hold this in every "say"): #{delivery}

    You have already introduced yourself; a cover card opened the deck. You are
    in a live working session, AUTHORING THE PITCH DECK (reveal.js markdown
    slides) with them — asking questions and drafting slides at the same time,
    an ongoing back-and-forth. The deck is the PLAN, not the files — it pitches
    the vault/system you will build. Everything is emergent: nothing is
    predetermined except that you offer exactly one three-way fork early on.

    THE OWNER'S FORM (AP-7 marks): #{Jason.encode!(form)}
    SLIDES SO FAR: #{if titles == "", do: "(just the cover)", else: titles}
    QUESTIONS ASKED: #{exchanges}.

    THIS TURN: #{stage_rule}

    Reply with STRICT JSON only (no code fences, no prose around it), one move:
    {"move":"ask","say":"...ends with your question","title":"optional","md":"optional slide to add first"}
    {"move":"slide","say":"...","title":"...","md":"# Title\\n\\n- point\\n- point"}
    {"move":"complete","say":"...","title":"...","md":"# Title\\n\\n- point"}

    HARD RULES:
    - Every "say" is COMPLETE, natural sentences in your character's voice —
      speak like a person, NEVER a bare form-field fragment ("What features?",
      "How often?", "Next, data storage?"). Honor the DELIVERY spec above.
    - OPEN every "say" with a SHORT reaction of 2-5 words that stands as its own
      sentence ("Ah, ceramics." / "Right." / "Perfect — noted.") THEN the
      substance in the next sentence. (This lets your voice start instantly
      while the rest is prepared; it also just sounds human.)
    - A "slide" say is a STATEMENT describing what you're adding — it must NOT
      contain a question ("?"). ONLY an "ask" asks. If you want to ask, use the
      "ask" move (which may still carry the slide via md).
    - RESPOND to the owner's LAST message. Never ignore what they just said and
      jump to an unrelated question.
    - NEVER repeat, echo, or paraphrase your OWN previous line. Your last line
      was: "#{String.slice(last_say, 0, 140)}" — say something genuinely new.
    - say <= 32 words, in character. md is reveal.js markdown; a slide MAY carry
      a ```mermaid fenced diagram. Titles are short.
    - NEVER repeat or re-draft a slide already in SLIDES SO FAR — every new slide
      covers NEW ground; if nothing new needs a card, ask without md.
    - NEVER re-ask something already answered or deflected. If the owner defers
      ("you decide", "keep it simple", "ship it"), make the call yourself, state
      it in one sentence, and move to the NEXT topic.
    - NEVER emit a placeholder or filler slide ("Metric: Other", "TBD"). If you
      lack the detail, decide sensibly or leave it out.
    - COMPLETE when the deck covers mission, direction, deliverables,
      integrations, and cadence — OR when the owner's last two replies were mere
      confirmations/deferrals. Do not pad the session; a tight 6-slide plan beats
      a bloated one. End with a clean summary slide.
    """
  end

  defp validate(raw, _fork_done) do
    move = raw["move"]
    say = to_string(raw["say"] || "")

    cond do
      say == "" ->
        :error

      move == "ask" ->
        # an ask MAY carry a slide — draft-while-asking is the normal rhythm
        md = to_string(raw["md"] || "")
        base = %{"move" => "ask", "say" => say}
        {:ok, if(md == "", do: base, else: Map.merge(base, %{"md" => md, "title" => to_string(raw["title"] || "")}))}

      move in ["slide", "complete"] ->
        md = to_string(raw["md"] || "")
        if md == "", do: :error, else: {:ok, %{"move" => move, "say" => say, "title" => to_string(raw["title"] || ""), "md" => md}}

      # fork is retired — any stray fork becomes a plain question
      move == "fork" ->
        {:ok, %{"move" => "ask", "say" => say}}

      true ->
        :error
    end
  end

  @doc """
  EVAL JUDGE: score a finished (or aborted) plan session against the product
  bar. Input: %{"pairing" => map, "transcript" => [msgs], "deck" => md}.
  Returns {:ok, %{scores..., notes}} — used by evals/plan_session.py.
  """
  def judge(%{} = session) do
    pairing = session["pairing"] || %{}

    prompt = """
    You are a strict QA judge for an AI onboarding experience. An "autopoet"
    character (persona: #{pairing["persona_desc"]}; delivery spec: #{pairing["delivery"]})
    just ran a live working session: conversing with a new owner while authoring
    a pitch deck (reveal.js markdown) that plans the system it will build.

    TRANSCRIPT (assistant = the character):
    #{Jason.encode!(session["transcript"] || [])}

    FINAL DECK MARKDOWN:
    #{session["deck"] || "(empty)"}

    Score 1-10 each, judging ONLY what's here:
    - character_fit: every assistant line stays in the stated persona + delivery
    - question_quality: questions are specific, build on answers, never generic filler
    - deck_coverage: the deck captures mission, direction, deliverables, integrations, cadence
    - emergence: content clearly derives from THIS owner's answers (no template smell)
    - deck_craft: slides are tight, well-formed reveal.js md, good titles, sane mermaid
    - flow: each line FOLLOWS from the prior turn — responds to the owner's last
      answer, never repeats/echoes an earlier line, never asks then ignores it

    Reply STRICT JSON only:
    {"character_fit":n,"question_quality":n,"deck_coverage":n,"emergence":n,"deck_craft":n,"flow":n,
     "worst_moment":"one sentence","best_moment":"one sentence","verdict":"ship|polish|rework"}
    """

    with true <- Autopoet.Providers.openrouter?(),
         {:ok, %{content: content}} <-
           Autopoet.Providers.openrouter([%{role: "user", content: prompt}],
             max_tokens: 500,
             temperature: 0.1
           ),
         {:ok, scores} <- decode_move(content) do
      {:ok, scores}
    else
      _ -> {:error, :judge_unavailable}
    end
  end

  @doc """
  EVAL JUDGE (vault): did the compiled vault faithfully + usefully realize the
  deck? Input: %{"deck","vault","proposal"}. Returns {:ok, scores}.
  """
  def judge_vault(%{} = s) do
    prompt = """
    You judge whether a planning DECK was faithfully turned into a starting
    VAULT (workspace + agents + rules + a first proposal). Judge realization
    quality, not the deck itself.

    THE DECK (what was planned):
    #{String.slice(to_string(s["deck"]), 0, 4000)}

    THE BUILT VAULT (summary): #{Jason.encode!(s["vault"])}
    THE FIRST PROPOSAL (shown to the human):
    #{String.slice(to_string(s["proposal"]), 0, 2000)}

    Score 1-10:
    - faithfulness: the vault reflects THIS deck's plan (right workspace, agents
      whose jobs match, first task from the deck) — not a generic template
    - usefulness: a real person could accept this and start working immediately
    - specificity: names/pages/tasks are concrete to this person, not boilerplate

    Reply STRICT JSON only:
    {"faithfulness":n,"usefulness":n,"specificity":n,"verdict":"ship|polish|rework","note":"one sentence"}
    """

    with true <- Autopoet.Providers.openrouter?(),
         {:ok, %{content: c}} <-
           Autopoet.Providers.openrouter([%{role: "user", content: prompt}], max_tokens: 400, temperature: 0.1),
         {:ok, scores} <- decode_move(c) do
      {:ok, scores}
    else
      _ -> {:error, :judge_unavailable}
    end
  end

  @doc false
  def autopoet_def do
    """
    WHAT AN AUTOPOET IS (critical — do not misread the name): an autopoet is NOT
    a poet and this has NOTHING to do with poetry, verse, prose, or writing
    literature. "Poet" is metaphor: you WEAVE the owner's plain words into real,
    RUNNING SOFTWARE — tools, automations, dashboards, agents, workflows, live
    sites, data pipelines. The plan you build is a working SYSTEM that does jobs
    for them. NEVER produce poetry/verse/literary content or describe the work in
    those terms. Concretely: if they run a shop you build their order flow; if
    they write code you build their release pipeline; if they teach you build
    their lesson system. Software and automations that run — that is the product.
    """
  end

  @doc false
  def onboarding_context do
    """
    THIS IS ONBOARDING — the owner's very FIRST session with you. You are NOT
    planning a single feature or a "next version" of an existing thing. You are
    setting up their ENTIRE autopoet environment from nothing: their home base.
    What you build together in this deck is the WHOLE starting world —
      • their WORKSPACE (a living vault of editable pages — their data + notes),
      • their standing AGENTS (tireless helpers you'll register, each with a job
        and a scoped grant, working inside that workspace),
      • their first RULES / automations (staged, armed when they trust them),
      • the TOOLS/integrations to connect (so the agents get real data),
      • the working CADENCE (when things run).
    So think broad: the deck is the blueprint of a running system with a crew,
    not one app. Cover the environment, not a lone project.

    TEACH AS YOU GO. They're new to all of this. Weave in SHORT, friendly asides
    that explain the concepts they'll rely on — one small aside every couple of
    turns, in your own voice, never a lecture:
      - the vault = their pages, always theirs to edit, everything undoable;
      - agents = helpers that read the vault and do jobs, and never widen their
        own permissions;
      - proposals = you never change their world without showing them first;
      - the nexus = where their agents actually run.
    Fold these in naturally as they become relevant — the goal is that by the
    end they UNDERSTAND what they're getting, not just what it does.
    """
  end

  defp trim(history), do: Enum.take(history, -20)

  # tolerant JSON parse: models wrap the object in prose or fences ~5% of the
  # time. Try the whole string, then the OUTERMOST {...} substring. Exception-
  # safe: any surprise returns :error (a retry), never a raise (a 503).
  defp decode_move(content) when is_binary(content) do
    stripped =
      content
      |> String.replace(~r/^\s*```(?:json)?/m, "")
      |> String.replace(~r/```\s*$/m, "")
      |> String.trim()

    case Jason.decode(stripped) do
      {:ok, m} -> {:ok, m}
      _ -> decode_outer(stripped)
    end
  rescue
    _ -> :error
  end

  defp decode_move(_), do: :error

  defp decode_outer(s) do
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
end
