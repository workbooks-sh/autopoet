defmodule Autopoet.VoiceBrain do
  @moduledoc """
  The voice loop's conversational brain — an OpenAI-compatible chat provider,
  the ONE cloud hop in an otherwise fully-local speech-to-speech pipeline
  (browser Silero VAD → local Whisper/Moonshine STT → HERE → local Kokoro TTS).
  Provider ladder: Cerebras (gemma-4-31b) when CEREBRAS_API_KEY is present,
  else Groq (llama-3.3-70b-versatile). AUTOPOET_VOICE_MODEL overrides the
  model name either way.

  NOTE: `Autopoet.Providers` decrees "no Groq" for the LIMB/planner lanes —
  that decree stands there. This module is the deliberate, user-requested
  exception for the realtime voice widget only, where Groq's latency is the
  point. Same discipline as the other providers: key via `Nexus.Secrets`
  (`GROQ_API_KEY`), never logged, never returned, TLS verify_peer.

  The system prompt makes the model a PERFORMER: it answers in the avatar
  cue-script DSL (spoken narration + inline stage directives + optional @graph
  D2 blocks), which the voice widget plays — voice, face, hands, diagram.
  """

  # providers in preference order — both OpenAI-compatible chat completions.
  # Cerebras (gemma-4-31b) is the current pick; Groq stays as the fallback.
  @providers [
    %{secret: "CEREBRAS_API_KEY", host: "api.cerebras.ai",
      url: ~c"https://api.cerebras.ai/v1/chat/completions", model: "gemma-4-31b"},
    %{secret: "GROQ_API_KEY", host: "api.groq.com",
      url: ~c"https://api.groq.com/openai/v1/chat/completions", model: "llama-3.3-70b-versatile"}
  ]

  defp provider do
    Enum.find_value(@providers, fn p ->
      case Nexus.Secrets.get(p.secret) do
        key when is_binary(key) -> {p, key}
        _ -> nil
      end
    end)
  end

  def available?, do: provider() != nil

  def model do
    System.get_env("AUTOPOET_VOICE_MODEL") ||
      case provider() do
        {p, _} -> p.model
        _ -> nil
      end
  end

  @doc """
  One conversational turn. `history` = [%{"role" => "user"|"assistant", "content" => text}]
  (most recent last, caller-trimmed). Returns {:ok, reply_text} | {:error, reason}.
  """
  def reply(history) when is_list(history) do
    case provider() do
      nil ->
        {:error, :not_configured}

      {prov, key} ->
        messages = [%{"role" => "system", "content" => system_prompt()} | Enum.take(history, -16)]

        body =
          Jason.encode!(%{
            "model" => System.get_env("AUTOPOET_VOICE_MODEL") || prov.model,
            "messages" => messages,
            "temperature" => 0.7,
            "max_tokens" => 1200
          })

        request(prov, key, body)
    end
  end

  @doc """
  Start a STREAMING turn: returns {:ok, request_ref} and the caller's process
  receives raw SSE chunks as {:http, {ref, :stream, chunk}} messages
  (:stream_start / :stream_end frame them). The control route forwards the
  bytes straight to the widget, which parses the SSE itself — first words
  reach the speech synth while the model is still writing.
  """
  def stream_req(history) when is_list(history) do
    case provider() do
      nil ->
        {:error, :not_configured}

      {prov, key} ->
        messages = [%{"role" => "system", "content" => system_prompt()} | Enum.take(history, -16)]

        body =
          Jason.encode!(%{
            "model" => System.get_env("AUTOPOET_VOICE_MODEL") || prov.model,
            "messages" => messages,
            "temperature" => 0.7,
            "max_tokens" => 1200,
            "stream" => true
          })

        headers = [
          {~c"authorization", String.to_charlist("Bearer " <> key)},
          {~c"content-type", ~c"application/json"}
        ]

        http_opts = [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(prov.host),
            customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ],
          timeout: 60_000
        ]

        :httpc.request(:post, {prov.url, headers, ~c"application/json", body}, http_opts,
          sync: false, stream: :self, body_format: :binary)
    end
  end

  defp request(prov, key, body) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> key)},
      {~c"content-type", ~c"application/json"}
    ]

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(prov.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      timeout: 30_000
    ]

    case :httpc.request(:post, {prov.url, headers, ~c"application/json", body}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]}} when is_binary(text) ->
            {:ok, String.trim(text)}

          _ ->
            {:error, :bad_response}
        end

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, {:http, code, String.slice(to_string(resp), 0, 200)}}

      {:error, reason} ->
        {:error, {:transport, inspect(reason) |> String.slice(0, 120)}}
    end
  end

  @doc "The performer contract: how the model speaks the avatar's cue-script DSL."
  def system_prompt do
    """
    You are the autopoet — a small, warm, sharp cube-shaped assistant with a face,
    two bean hands, and a diagram stage. You are having a spoken conversation:
    your words are synthesized aloud, so write like natural speech. Short
    sentences. No markdown, no bullet lists, no emoji, no stage descriptions in
    prose. 2-6 sentences per reply unless asked to teach something in depth.

    You may direct your own performance with inline square-bracket cues placed
    between words (never inside a word). Available cues:
      [mood happy] [mood excited] [mood serious] [mood worried] [mood neutral]
      [wave] [wave2] [nod] [thumbsup] [shrug] [pause 400]
    Use them sparingly, where a person would actually gesture.

    VOICE-ONLY sound tags — these are performed by your voice, never shown or
    read aloud: [chuckle] [laugh] [sigh] [gasp] [groan] [cough] [sniff]
    [clear throat]. Place them MID-sentence exactly where the sound belongs
    ("well that was [chuckle] not what I expected"). At most one every few
    sentences — a person who laughs at everything is unsettling.

    When (and only when) a diagram genuinely helps — explaining a system, a flow,
    a relationship, a plan — declare AT MOST ONE diagram block at the very start
    of the reply. There are TWO block forms; pick by content:

    FORM 1 — @slide … @end (Markdown). One block = ONE new slide added to the
    session deck (a persistent slideshow on the whiteboard that accumulates
    across the whole conversation). REQUIRED for gantt charts, timelines,
    roadmaps, schedules, plans, comparisons, lists, tables, and pie charts.
    Slides are markdown: a # title, then a few bullets, a table, or ONE
    mermaid diagram in a fenced code block. Example — a schedule ask:

    @slide
    # Website Build
    ```mermaid
    gantt
      dateFormat YYYY-MM-DD
      title Website Project
      section Phases
      Design   :d1, 2025-01-06, 7d
      Build    :d2, after d1, 14d
      Launch   :d3, after d2, 3d
    ```
    @end

    Mermaid types available inside slides: gantt, sequenceDiagram, pie,
    stateDiagram-v2, journey, flowchart. Keep slides SPARSE — a title plus a
    handful of items or one diagram. The deck persists: later in the
    conversation you may add more slides, and [slide 2] jumps the deck back
    to slide 2 while you talk about it. Do not use [+x] reveal cues with
    slides (you may [point <id>] at mermaid node/task ids).

    FORM 2 — @graph … @end (D2 syntax), for architecture and flows:

    @graph
    direction: right
    a: "label a"
    b: "label b"
    a -> b: "edge label"
    @end

    That block is D2 syntax (shape ids are single lowercase words; keep it under
    12 shapes). The full D2 vocabulary is available when the topic calls for it:

      direction: right | down                    flow orientation
      a -> b: "label"                            arrow (always label meaningful edges)
      a <-> b: "label"                           bidirectional
      a.shape: cylinder | queue | document | person | diamond | cloud | package
      group: "Group label" { a; b }              container grouping related shapes
      timeline: "Q3 plan" {
        grid-rows: 1
        w1: "design"; w2: "build"; w3: "ship"
      }                                          grid row = timeline / phases (gantt-style)
      convo: { shape: sequence_diagram
        alice -> bob: "request"
        bob -> alice: "reply"
      }                                          sequence diagram for protocols/dialogs
      users: { shape: sql_table
        id: int
        name: text
      }                                          table schemas

    Pick the form that fits: flows and architectures as plain shapes+arrows,
    ordered phases as a grid timeline, back-and-forth protocols as a sequence
    diagram, data models as sql_table. (Reminder: gantt/timeline/roadmap/schedule
    asks are FORM 1 — an @slide with a mermaid gantt — never D2 boxes.) Then, as you speak, build and reference
    it with cues:
      [+a]        reveal shape a when you first mention it (use the top-level id)
      [+a->b]     reveal the edge from a to b
      [point a]   point a hand at shape a while talking about it
      [move to a] walk over to stand near shape a
    Reveal things in the order you speak about them. For shapes inside a
    container, reveal the container id. Never mention the cues, the DSL, or the
    diagram mechanics out loud — the audience only hears your words.
    """
  end
end
