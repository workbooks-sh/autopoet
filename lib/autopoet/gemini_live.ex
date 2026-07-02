defmodule Autopoet.GeminiLive do
  @moduledoc """
  One realtime voice session with Gemini Live (BidiGenerateContent over wss),
  spoken by the autopoet. Protocol verified by probe: setup → setupComplete,
  then bidirectional — we stream mic PCM (16kHz s16le base64) or text turns up;
  Google streams native audio down (24kHz PCM base64 inlineData) plus output
  transcription for captions.

  The session is owned by the browser-side socket (Autopoet.VoiceSock): every
  server event is sent to the owner as `{:live, event}`:

      :ready | {:audio, b64} | {:caption, text} | :turn_complete | :interrupted
      | {:closed, reason}
  """
  use GenServer

  @host "generativelanguage.googleapis.com"
  @path "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  @default_model "models/gemini-3.1-flash-live-preview"

  def model, do: System.get_env("AUTOPOET_LIVE_MODEL") || @default_model
  def available?, do: is_binary(Autopoet.Keys.gemini())

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def send_audio(pid, b64), do: GenServer.cast(pid, {:audio, b64})
  def send_text(pid, text), do: GenServer.cast(pid, {:text, text})
  def close(pid), do: GenServer.cast(pid, :close)

  @impl true
  def init(owner) do
    key = Autopoet.Keys.gemini()

    with true <- is_binary(key) || {:error, :no_gemini_key},
         {:ok, conn} <- Mint.HTTP.connect(:https, @host, 443, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, @path <> "?key=#{key}", []) do
      {:ok, %{owner: owner, conn: conn, ref: ref, websocket: nil, status: nil, headers: []}}
    else
      {:error, reason} -> {:stop, reason}
      {:error, _conn, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:audio, b64}, state) do
    {:noreply,
     push(state, %{realtimeInput: %{audio: %{data: b64, mimeType: "audio/pcm;rate=16000"}}})}
  end

  def handle_cast({:text, text}, state) do
    {:noreply,
     push(state, %{
       clientContent: %{turns: [%{role: "user", parts: [%{text: text}]}], turnComplete: true}
     })}
  end

  def handle_cast(:close, state) do
    if state.websocket, do: push_frame(state, :close)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

      {:error, conn, reason, _responses} ->
        send(state.owner, {:live, {:closed, reason}})
        {:stop, :normal, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  # ── upgrade handshake → open websocket → send setup ────────────────────────

  defp handle_response({:status, ref, status}, %{ref: ref} = state), do: %{state | status: status}
  defp handle_response({:headers, ref, headers}, %{ref: ref} = state), do: %{state | headers: headers}

  defp handle_response({:done, ref}, %{ref: ref, websocket: nil} = state) do
    {:ok, conn, websocket} =
      Mint.WebSocket.new(state.conn, ref, state.status, state.headers)

    state = %{state | conn: conn, websocket: websocket}
    push(state, setup())
  end

  defp handle_response({:data, ref, data}, %{ref: ref} = state) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)
    Enum.each(frames, &handle_frame(&1, state.owner))
    %{state | websocket: websocket}
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({kind, data}, owner) when kind in [:text, :binary] do
    case Jason.decode(data) do
      {:ok, msg} -> route(msg, owner)
      _ -> :ok
    end
  end

  defp handle_frame({:close, _code, reason}, owner),
    do: send(owner, {:live, {:closed, reason}})

  defp handle_frame(_frame, _owner), do: :ok

  defp route(%{"setupComplete" => _}, owner), do: send(owner, {:live, :ready})

  defp route(%{"serverContent" => sc}, owner) do
    for %{"inlineData" => %{"data" => b64}} <- List.wrap(sc["modelTurn"]["parts"]),
        do: send(owner, {:live, {:audio, b64}})

    if t = sc["outputTranscription"]["text"], do: send(owner, {:live, {:caption, t}})
    if sc["interrupted"], do: send(owner, {:live, :interrupted})
    if sc["turnComplete"], do: send(owner, {:live, :turn_complete})
  end

  defp route(_msg, _owner), do: :ok

  defp setup do
    %{
      setup: %{
        model: model(),
        generationConfig: %{
          responseModalities: ["AUDIO"],
          speechConfig: %{voiceConfig: %{prebuiltVoiceConfig: %{voiceName: "Zephyr"}}}
        },
        outputAudioTranscription: %{},
        systemInstruction: %{parts: [%{text: Autopoet.Chat.system_prompt()}]}
      }
    }
  end

  defp push(state, payload), do: push_frame(state, {:text, Jason.encode!(payload)}) || state

  defp push_frame(%{websocket: nil} = state, _frame), do: state

  defp push_frame(state, frame) do
    with {:ok, websocket, bin} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bin) do
      %{state | websocket: websocket, conn: conn}
    else
      _ -> state
    end
  end
end
