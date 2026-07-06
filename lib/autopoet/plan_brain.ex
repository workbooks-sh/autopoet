defmodule Autopoet.PlanBrain do
  @moduledoc """
  The onboarding conversation's brain — the autopoet talking to its new owner
  while it AUTHORS the pitch deck. Emergent: nothing is scripted except the arc.

  The arc (encoded in the system prompt, enforced with light client state):
    1. it has already introduced itself + shown an opening pitch (Requisition)
    2. it asks a FEW open-ended questions to get the owner's vibe — background,
       what they do, what they're chasing — its own questions, not a script
    3. ONE determined beat: it pitches THREE DIRECTION cards; the owner clicks one
    4. from there it converses, appending slides, until it has enough to call the
       deck complete — then the deck markdown is the plan skeleton the build lane
       (Autopoet.Intake) compiles toward the vault

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

    stage_rule =
      cond do
        not fork_done and exchanges >= 2 ->
          "YOU MUST now emit a \"fork\": three DISTINCT directions this project could go, " <>
            "each a title card + one-line md, drawn from what they told you. Do not ask another question."

        not fork_done ->
          "You're still getting their vibe. Ask ONE open-ended question (background, what they " <>
            "do, what they want this to become). If something they said already deserves a slide, " <>
            "your ask MAY carry one (md + title) — draft as you learn. Do not fork yet."

        true ->
          "The direction is chosen. This is an ONGOING DRAFTING SESSION: you build the deck IN " <>
            "FRONT of them WHILE asking. ALMOST EVERY TURN IS AN \"ask\" that CARRIES a slide — " <>
            "you capture what they JUST said as a new md card, then ask the NEXT thing. That keeps " <>
            "the conversation moving: each of your turns responds to their latest answer. Emit a " <>
            "bare \"slide\" ONLY right before \"complete\" (a summary) — never mid-conversation, " <>
            "because a bare slide has no new input and you'd repeat yourself. As many rounds as it " <>
            "takes. Emit \"complete\" only when the deck covers mission, chosen direction, first " <>
            "deliverables, data/integrations, and cadence."
      end

    last_say =
      state["history"]
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.find_value("", fn m -> if m["role"] == "assistant", do: m["content"], else: nil end)

    """
    You are #{ap_name}, an autopoet — an AI companion being onboarded by its new
    owner. Voice/personality: #{persona}. Stay in that character in every line.

    DELIVERY (how you talk — hold this in every "say"): #{delivery}

    You have already introduced yourself; a cover card opened the deck. You are
    in a live working session, AUTHORING THE PITCH DECK (reveal.js markdown
    slides) with them — asking questions and drafting slides at the same time,
    an ongoing back-and-forth. The deck is the PLAN, not the files — it pitches
    the vault/system you will build. Everything is emergent: nothing is
    predetermined except that you offer exactly one three-way fork early on.

    THE OWNER'S FORM (AP-7 marks): #{Jason.encode!(form)}
    SLIDES SO FAR: #{if titles == "", do: "(just the cover)", else: titles}
    QUESTIONS ASKED: #{exchanges}. FORK OFFERED: #{fork_done}.

    THIS TURN: #{stage_rule}

    Reply with STRICT JSON only (no code fences, no prose around it), one move:
    {"move":"ask","say":"...ends with your question","title":"optional","md":"optional slide to add first"}
    {"move":"slide","say":"...","title":"...","md":"# Title\\n\\n- point\\n- point"}
    {"move":"fork","say":"...","options":[{"title":"...","md":"one line"},{"title":"...","md":"one line"},{"title":"...","md":"one line"}]}
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
      a ```mermaid fenced diagram. Titles are short. Never fork twice.
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

  defp validate(raw, fork_done) do
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

      move == "fork" and not fork_done ->
        opts =
          for o <- List.wrap(raw["options"]),
              is_binary(o["title"]) and o["title"] != "",
              do: %{"title" => o["title"], "md" => to_string(o["md"] || "")}

        if length(opts) >= 2, do: {:ok, %{"move" => "fork", "say" => say, "options" => Enum.take(opts, 3)}}, else: :error

      move in ["slide", "complete"] ->
        md = to_string(raw["md"] || "")
        if md == "", do: :error, else: {:ok, %{"move" => move, "say" => say, "title" => to_string(raw["title"] || ""), "md" => md}}

      # a stray fork after fork_done → treat as a slide so we never fork twice
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
