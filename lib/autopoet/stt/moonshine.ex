defmodule Autopoet.Stt.Moonshine do
  @moduledoc """
  Moonshine-base speech-to-text on the ONNX lane — official graphs run
  in-process via Ortex, greedy decode loop in plain Elixir, same
  `tokenizer.json` via the `Tokenizers` NIF. No python anywhere.

  Uses the NON-MERGED decoder pair (onnx-community/moonshine-base-ONNX,
  encoder byte-identical to UsefulSensors' own export):

    * `decoder_model` — first step: (input_ids, encoder_hidden_states) →
      logits + all 32 present KV (decoder self-attn AND encoder cross-attn)
    * `decoder_with_past_model` — every later step: (input_ids, past × 32) →
      logits + 16 DECODER presents; cross-attn KV is reused from step one

  The HF-Optimum MERGED graph is a trap for Ortex: its cached branch emits
  EMPTY placeholder tensors for the unchanged encoder presents, and Ortex's
  eager output marshaling dies on them (GetTensorMutableData null). The pair
  has no conditional branches and no empty outputs — clean contract.

  Loop semantics mirror moonshine_onnx/model.py (the verification oracle):
  greedy argmax, start=1, eos=2, max 192 tokens, audio 0.1–64s 16kHz mono.
  Files ship under `data/models/moonshine/` — nothing downloads at
  transcribe time.
  """

  @start_token 1
  @eos_token 2
  @max_tokens 192
  @max_samples 64 * 16_000

  defstruct [:encoder, :decoder, :decoder_with_past, :tokenizer]

  @doc "Load the engine from a directory of shipped model files (nil if absent)."
  def load(dir) do
    files = %{
      encoder: Path.join(dir, "encoder_model.onnx"),
      decoder: Path.join(dir, "decoder_model.onnx"),
      decoder_with_past: Path.join(dir, "decoder_with_past_model.onnx"),
      tokenizer: Path.join(dir, "tokenizer.json")
    }

    with true <- Enum.all?(files, fn {_, p} -> File.exists?(p) end),
         {:ok, tokenizer} <- Tokenizers.Tokenizer.from_file(files.tokenizer) do
      %__MODULE__{
        encoder: Ortex.load(files.encoder),
        decoder: Ortex.load(files.decoder),
        decoder_with_past: Ortex.load(files.decoder_with_past),
        tokenizer: tokenizer
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Warm the sessions with half a second of silence — binds ORT symbols at boot."
  def bind(%__MODULE__{} = m) do
    silence = Nx.broadcast(Nx.tensor(0.0, type: :f32), {1, 8000})
    transcribe(m, silence)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Transcribe a mono 16kHz f32 tensor of shape {1, samples}."
  def transcribe(%__MODULE__{} = m, audio) do
    audio =
      case Nx.shape(audio) do
        {1, n} when n > @max_samples -> Nx.slice(audio, [0, 0], [1, @max_samples])
        {1, _} -> audio
      end

    {hidden} = Ortex.run(m.encoder, {audio})
    hidden = Nx.backend_transfer(hidden)

    # step one: no cache — emits every present, including the cross-attn KV
    # that all later steps reuse untouched
    outs = Ortex.run(m.decoder, {Nx.tensor([[@start_token]], type: :s64), hidden})
    [logits | presents] = Tuple.to_list(outs)
    past = Enum.map(presents, &Nx.backend_transfer/1)
    first = argmax_last(logits)

    tokens =
      if first == @eos_token,
        do: [],
        else: decode_loop(m, past, first, [first], 1)

    case Tokenizers.Tokenizer.decode(m.tokenizer, tokens) do
      {:ok, text} -> {:ok, String.trim(text)}
      err -> {:error, {:detokenize, err}}
    end
  end

  defp decode_loop(_m, _past, _tok, tokens, i) when i >= @max_tokens, do: Enum.reverse(tokens)

  defp decode_loop(m, past, tok, tokens, i) do
    inputs = List.to_tuple([Nx.tensor([[tok]], type: :s64) | past])
    [logits | dec_presents] = m.decoder_with_past |> Ortex.run(inputs) |> Tuple.to_list()
    next = argmax_last(logits)

    if next == @eos_token do
      Enum.reverse(tokens)
    else
      # with_past emits ONLY the 16 decoder presents (layer-major key,value);
      # slot them back into the 4-per-layer past, cross-attn entries untouched
      past =
        past
        |> Enum.with_index()
        |> Enum.map(fn {old, idx} ->
          layer = div(idx, 4)

          case rem(idx, 4) do
            0 -> Nx.backend_transfer(Enum.at(dec_presents, layer * 2))
            1 -> Nx.backend_transfer(Enum.at(dec_presents, layer * 2 + 1))
            _ -> old
          end
        end)

      decode_loop(m, past, next, [next | tokens], i + 1)
    end
  end

  defp argmax_last(logits) do
    logits
    |> Nx.backend_transfer()
    |> then(& &1[0][-1])
    |> Nx.argmax()
    |> Nx.to_number()
  end
end
