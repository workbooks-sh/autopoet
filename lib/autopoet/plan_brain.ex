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
      not Autopoet.Providers.openrouter?() -> {:error, :no_brain}
      true ->
        case ask_llm(state, history, fork_done, exchanges) do
          {:ok, move} -> {:ok, move}
          _ -> {:error, :bad_turn}
        end
    end
  end

  defp ask_llm(state, history, fork_done, exchanges) do
    prompt = [%{"role" => "system", "content" => system_prompt(state, fork_done, exchanges)} | trim(history)]

    with {:ok, %{content: content}} <-
           Autopoet.Providers.openrouter(prompt, max_tokens: 1100, temperature: 0.7),
         {:ok, raw} <- Jason.decode(strip_fences(content)),
         {:ok, move} <- validate(raw, fork_done) do
      {:ok, move}
    else
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
            "FRONT of them WHILE asking — most turns should be an \"ask\" carrying a slide (capture " <>
            "what they just gave you as md, then ask the next thing). Use a bare \"slide\" only to " <>
            "chain an extra card between questions. As many rounds as it takes — there is no slide " <>
            "count or turn count. Emit \"complete\" ONLY when the deck genuinely covers what you " <>
            "need to build: the mission, the chosen direction, the first concrete deliverables, the " <>
            "data/integrations involved, and the working cadence. If any of those is still fuzzy, " <>
            "keep asking."
      end

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
    Rules: say <= 32 words, in character. md is reveal.js markdown; a slide MAY
    carry a ```mermaid fenced diagram. Titles are short. Never fork twice.
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

  defp trim(history), do: Enum.take(history, -20)

  defp strip_fences(s) do
    s
    |> String.replace(~r/^\s*```(?:json)?/m, "")
    |> String.replace(~r/```\s*$/m, "")
    |> String.trim()
  end
end
