defmodule Autopoet.Affect do
  @moduledoc """
  BEAM-native emotion understanding — REAL NLP, not a word list. The GoEmotions
  RoBERTa classifier (28 conversational emotion labels, int8 ONNX) runs
  in-process on the same Ortex lane as Moonshine and Kokoro. It reads "I got
  food poisoning and I feel terrible" as sadness/disgust without anyone having
  enumerated "poisoning" — that generalization is the whole point.

  The voice widget calls this on every LIVE moonshine partial (~500ms cadence);
  inference on a short utterance is a few ms of CPU, so the emotional read
  lands within the same tick as the words. The widget keeps its rule layer for
  the SOCIAL routing a classifier can't do (who feels it, hope/fear arcs,
  rhetorical vs curious questions) and feeds it these scores instead of
  lexicon counts.

  Files under `data/models/affect/` (model_quantized.onnx + tokenizer.json,
  from SamLowe/roberta-base-go_emotions-onnx). Nothing downloads at classify
  time.
  """
  use GenServer

  # label order = the model config's id2label, verbatim
  @labels ~w(admiration amusement anger annoyance approval caring confusion
             curiosity desire disappointment disapproval disgust embarrassment
             excitement fear gratitude grief joy love nervousness optimism
             pride realization relief remorse sadness surprise neutral)

  # ── public API ─────────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def ready? do
    GenServer.call(__MODULE__, :ready?, 1_000)
  catch
    :exit, _ -> false
  end

  @doc "Classify text → {:ok, [{label, score}]} (top k, sigmoid scores desc)."
  def classify(text, k \\ 5) do
    GenServer.call(__MODULE__, {:classify, text, k}, 10_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, nil, {:continue, :load}}

  @impl true
  def handle_continue(:load, _state) do
    engine = load_dir(dir())
    if engine, do: Autopoet.Log.puts("affect: GoEmotions classifier up (28 labels, BEAM-native)")
    {:noreply, engine}
  end

  # Autopoet.Weights lands the model files after boot → re-run the load
  @impl true
  def handle_cast(:reload, nil), do: {:noreply, nil, {:continue, :load}}
  def handle_cast(:reload, engine), do: {:noreply, engine}

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state != nil, state}

  def handle_call({:classify, _text, _k}, _from, nil), do: {:reply, {:error, :not_ready}, nil}

  def handle_call({:classify, text, k}, _from, engine) do
    {:reply, infer(engine, text, k), engine}
  end

  # ── engine (pure — testable without the GenServer) ─────────────────────────

  def dir, do: Path.join(Autopoet.Discovery.models_dir(), "affect")

  def load_dir(dir) do
    model = Path.join(dir, "model_quantized.onnx")
    tok = Path.join(dir, "tokenizer.json")

    with true <- File.exists?(model),
         {:ok, tokenizer} <- Tokenizers.Tokenizer.from_file(tok) do
      %{model: Ortex.load(model), tokenizer: tokenizer}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Pure inference against a loaded engine."
  def infer(engine, text, k) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 500)

    with {:ok, enc} <- Tokenizers.Tokenizer.encode(engine.tokenizer, text) do
      ids = Tokenizers.Encoding.get_ids(enc)
      n = length(ids)

      {logits} =
        Ortex.run(engine.model, {
          Nx.tensor([ids], type: :s64),
          Nx.tensor([List.duplicate(1, n)], type: :s64)
        })

      scores =
        logits
        |> Nx.backend_transfer()
        |> Nx.flatten()
        |> Nx.sigmoid()
        |> Nx.to_flat_list()

      top =
        @labels
        |> Enum.zip(scores)
        |> Enum.sort_by(fn {_, s} -> -s end)
        |> Enum.take(k)
        |> Enum.map(fn {l, s} -> {l, Float.round(s * 1.0, 4)} end)

      {:ok, top}
    end
  rescue
    e -> {:error, {:affect, Exception.message(e) |> String.slice(0, 120)}}
  end
end
