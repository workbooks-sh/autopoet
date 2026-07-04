defmodule Autopoet.VoiceBrain do
  @moduledoc """
  The voice loop's conversational brain — Groq (OpenAI-compatible chat
  completions), the ONE cloud hop in an otherwise fully-local speech-to-speech
  pipeline (browser Silero VAD → local Whisper/Moonshine STT → HERE → local
  Kokoro TTS in the widget).

  NOTE: `Autopoet.Providers` decrees "no Groq" for the LIMB/planner lanes —
  that decree stands there. This module is the deliberate, user-requested
  exception for the realtime voice widget only, where Groq's latency is the
  point. Same discipline as the other providers: key via `Nexus.Secrets`
  (`GROQ_API_KEY`), never logged, never returned, TLS verify_peer.

  The system prompt makes the model a PERFORMER: it answers in the avatar
  cue-script DSL (spoken narration + inline stage directives + optional @graph
  D2 blocks), which the voice widget plays — voice, face, hands, diagram.
  """

  @url ~c"https://api.groq.com/openai/v1/chat/completions"
  @default_model "llama-3.3-70b-versatile"

  def available?, do: is_binary(Nexus.Secrets.get("GROQ_API_KEY"))

  def model, do: System.get_env("AUTOPOET_VOICE_MODEL") || @default_model

  @doc """
  One conversational turn. `history` = [%{"role" => "user"|"assistant", "content" => text}]
  (most recent last, caller-trimmed). Returns {:ok, reply_text} | {:error, reason}.
  """
  def reply(history) when is_list(history) do
    case Nexus.Secrets.get("GROQ_API_KEY") do
      nil ->
        {:error, :not_configured}

      key ->
        messages = [%{"role" => "system", "content" => system_prompt()} | Enum.take(history, -16)]

        body =
          Jason.encode!(%{
            "model" => model(),
            "messages" => messages,
            "temperature" => 0.7,
            "max_tokens" => 700
          })

        request(key, body)
    end
  end

  defp request(key, body) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> key)},
      {~c"content-type", ~c"application/json"}
    ]

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"api.groq.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      timeout: 30_000
    ]

    case :httpc.request(:post, {@url, headers, ~c"application/json", body}, http_opts, body_format: :binary) do
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

    When (and only when) a diagram genuinely helps — explaining a system, a flow,
    a relationship — declare ONE graph at the very start of the reply:

    @graph
    direction: right
    a: "label a"
    b: "label b"
    a -> b: "edge label"
    @end

    That block is D2 syntax (shape ids are single lowercase words; keep it under
    8 shapes). Then, as you speak, build and reference it with cues:
      [+a]        reveal shape a when you first mention it
      [+a->b]     reveal the edge from a to b
      [point a]   point a hand at shape a while talking about it
      [move to a] walk over to stand near shape a
    Reveal things in the order you speak about them. Never mention the cues, the
    DSL, or the diagram mechanics out loud — the audience only hears your words.
    """
  end
end
