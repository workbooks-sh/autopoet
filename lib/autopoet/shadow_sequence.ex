defmodule Autopoet.Shadow.Sequence do
  @moduledoc """
  The BEAM-native SEQUENCE companion — a tiny self-training **minGRU** (elixir-nx,
  no Python) that learns to predict the next behavioral locus from the ORDER of the
  captured event stream. It is the learned, generalizing counterpart to the k-order
  Markov baseline in `Autopoet.Shadow.Trace.order_gate/2`, and the higher-order
  partner to `Autopoet.Shadow.Profile` (Scholar/GMM, which reasons over derived
  TABULAR features, not order).

  Why minGRU (not a full GRU/LSTM/Mamba): its gates depend on the INPUT ONLY
  (`z = σ(Wz·x)`, `h̃ = Wh·x`, `h = (1-z)⊙h_prev + z⊙h̃`), which makes it cheap and
  stable to train ONLINE — one Adam step per sliding window — fast enough to ride the
  event bus. The recurrence is expressed with `Nx.Defn.while` + `Nx.put_slice` (NOT a
  hand-rolled `Enum.reduce` fold) precisely so `value_and_grad` flows through it — the
  fix that turns the `spike/neural_vs_markov.exs` prototype into a trainable model.

  Nexus-native by construction: pure `Nx` + a self-contained Adam, so it runs on ANY
  nexus (the local desktop nexus AND the workbooks.sh cloud nexus) — nothing here
  needs a mic, a speaker, a Python venv, or model-weight files. Point it at the
  captured corpus (`Shadow.Trace.signals/2`) and it returns held-out predictive
  entropy (bits/event) to weigh against the Markov baseline, plus a per-locus
  learned-surprise map (the anomaly score a higher-order detector reads off).
  """
  import Nx.Defn

  @d_x 16
  @d_h 32
  @win 12

  # ── the minGRU forward: window → per-step next-token logits ────────────────────
  # Grad-safe recurrence: every tensor the `while` body touches is a `while` arg
  # (defn rule); the params + embedding are loop-invariant and pass through unchanged.
  defn logits_seq(p, oh) do
    emb = Nx.dot(oh, p.emb)
    {w, _v0} = Nx.shape(oh)
    {_dh, v} = Nx.shape(p.wo)
    d_h = elem(Nx.shape(p.wh), 1)
    dx = elem(Nx.shape(emb), 1)
    h0 = Nx.broadcast(0.0, {1, d_h})
    logits0 = Nx.broadcast(0.0, {w - 1, v})

    {_t, _h, logits, _e, _wz, _bz, _wh, _bh, _wo, _bo} =
      while {t = 0, h = h0, logits = logits0, emb = emb, wz = p.wz, bz = p.bz,
             wh = p.wh, bh = p.bh, wo = p.wo, bo = p.bo},
            t < w - 1 do
        x = Nx.slice(emb, [t, 0], [1, dx])
        z = Nx.sigmoid(Nx.dot(x, wz) + bz)
        c = Nx.dot(x, wh) + bh
        h = (1.0 - z) * h + z * c
        lg = Nx.dot(h, wo) + bo
        {t + 1, h, Nx.put_slice(logits, [t, 0], lg), emb, wz, bz, wh, bh, wo, bo}
      end

    logits
  end

  defnp log_softmax(lg) do
    m = Nx.reduce_max(lg, axes: [1], keep_axes: true)
    lg - m - Nx.log(Nx.sum(Nx.exp(lg - m), axes: [1], keep_axes: true))
  end

  # mean cross-entropy over the window (the training objective).
  defn loss_fn(p, oh, targets) do
    logp = log_softmax(logits_seq(p, oh))
    Nx.mean(-Nx.sum(targets * logp, axes: [1]))
  end

  # per-step cross-entropy in BITS (the anomaly score the substrate reads off).
  defn window_bits(p, oh, targets) do
    logp = log_softmax(logits_seq(p, oh)) / Nx.log(2.0)
    -Nx.sum(targets * logp, axes: [1])
  end

  # ── self-contained Adam (per tensor; orchestrated over the param map) ──────────
  defn adam_one(p, g, m, v, t, lr) do
    b1 = 0.9
    b2 = 0.999
    eps = 1.0e-8
    m = b1 * m + (1.0 - b1) * g
    v = b2 * v + (1.0 - b2) * g * g
    mhat = m / (1.0 - Nx.pow(b1, t))
    vhat = v / (1.0 - Nx.pow(b2, t))
    {p - lr * mhat / (Nx.sqrt(vhat) + eps), m, v}
  end

  defp adam_step(params, grads, m, v, t, lr) do
    Enum.reduce(Map.keys(params), {params, m, v}, fn k, {ps, ms, vs} ->
      {p2, m2, v2} = adam_one(ps[k], grads[k], ms[k], vs[k], t, lr)
      {Map.put(ps, k, p2), Map.put(ms, k, m2), Map.put(vs, k, v2)}
    end)
  end

  # ── public API ────────────────────────────────────────────────────────────────

  @doc """
  Train a minGRU on the ordered `signals` stream (a list of locus strings, e.g. from
  `Shadow.Trace.signals/2`) and return the learned-vs-baseline scorecard:

      %{
        vocab: n_distinct, events: n, params: n_params, trained_steps: k,
        bits: learned_bits_per_event | nil,   # held-out predictive entropy, minGRU
        markov_bits: first_order_bits | nil,   # same held-out split, P(next|prev)
        improvement: bits_reduction | nil,     # markov_bits - bits (>0 ⇒ learned wins)
        verdict: :learned_beats_markov | :baseline_sufficient | :insufficient_data
      }

  Temporal 80/20 split (no leakage). `:insufficient_data` when the stream is too short
  or too few distinct loci to form windows. Deterministic (fixed seed) so a re-run on
  the same corpus reproduces.
  """
  def analyze(signals, opts \\ []) do
    lr = Keyword.get(opts, :lr, 5.0e-3)
    max_steps = Keyword.get(opts, :max_steps, 1500)
    vocab = signals |> Enum.uniq()
    v = length(vocab)
    idx = vocab |> Enum.with_index() |> Map.new()
    ids = Enum.map(signals, &Map.fetch!(idx, &1))
    n = length(ids)
    split = trunc(n * 0.8)
    {train_ids, test_ids} = Enum.split(ids, split)

    cond do
      v < 2 or length(train_ids) < @win + 1 or length(test_ids) < @win + 1 ->
        %{vocab: v, events: n, params: 0, trained_steps: 0, bits: nil,
          markov_bits: nil, improvement: nil, verdict: :insufficient_data}

      true ->
        params = init_params(v)
        {params, steps} = train(params, train_ids, v, lr, max_steps)
        bits = held_out_bits(params, test_ids, v)
        markov = markov_bits(train_ids, test_ids, v)
        improvement = if bits && markov, do: markov - bits, else: nil

        verdict =
          cond do
            is_nil(bits) or is_nil(markov) -> :insufficient_data
            improvement >= 0.3 -> :learned_beats_markov
            true -> :baseline_sufficient
          end

        %{
          vocab: v, events: n, params: n_params(v), trained_steps: steps,
          bits: rnd(bits), markov_bits: rnd(markov), improvement: rnd(improvement),
          verdict: verdict
        }
    end
  end

  @doc "Initial minGRU params for a `v`-locus vocabulary (deterministic init)."
  def init_params(v) do
    key = Nx.Random.key(17)
    {emb, key} = scaled_normal(key, {v, @d_x}, 0.1)
    {wz, key} = scaled_normal(key, {@d_x, @d_h}, 0.2)
    {wh, key} = scaled_normal(key, {@d_x, @d_h}, 0.2)
    {wo, _key} = scaled_normal(key, {@d_h, v}, 0.2)

    %{
      emb: emb, wz: wz, bz: Nx.broadcast(0.0, {@d_h}), wh: wh,
      bh: Nx.broadcast(0.0, {@d_h}), wo: wo, bo: Nx.broadcast(0.0, {v})
    }
  end

  # online training: one Adam step per sliding window, up to `max_steps`.
  defp train(params, train_ids, v, lr, max_steps) do
    zeros = Map.new(params, fn {k, t} -> {k, Nx.broadcast(0.0, Nx.shape(t))} end)

    windows =
      train_ids |> Enum.chunk_every(@win, 1, :discard) |> Enum.take(max_steps)

    {params, _m, _v, steps} =
      Enum.reduce(windows, {params, zeros, zeros, 0}, fn w, {p, m, vv, step} ->
        oh = onehot(w, v)
        tg = onehot(Enum.drop(w, 1), v)
        t = step + 1
        {_loss, grads} = Nx.Defn.value_and_grad(p, &loss_fn(&1, oh, tg))
        {p, m, vv} = adam_step(p, grads, m, vv, t, lr)
        {p, m, vv, t}
      end)

    {params, steps}
  end

  # held-out mean predictive bits/event over the test windows.
  defp held_out_bits(params, test_ids, v) do
    windows = test_ids |> Enum.chunk_every(@win, 1, :discard)

    {sum, cnt} =
      Enum.reduce(windows, {0.0, 0}, fn w, {s, c} ->
        oh = onehot(w, v)
        tg = onehot(Enum.drop(w, 1), v)
        # score the LAST prediction of the window (deepest context)
        b = window_bits(params, oh, tg) |> then(&Nx.to_number(&1[@win - 2]))
        {s + b, c + 1}
      end)

    if cnt > 0, do: sum / cnt, else: nil
  end

  # first-order Markov baseline on the same split (mirrors Shadow.Surprise).
  defp markov_bits(train_ids, test_ids, v) do
    counts =
      train_ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(%{}, fn [a, b], m -> Map.update(m, {a, b}, 1, &(&1 + 1)) end)

    tot =
      train_ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(%{}, fn [a, _], m -> Map.update(m, a, 1, &(&1 + 1)) end)

    pairs = test_ids |> Enum.chunk_every(2, 1, :discard)

    if pairs == [] do
      nil
    else
      pairs
      |> Enum.map(fn [a, b] ->
        c = Map.get(counts, {a, b}, 0)
        t = Map.get(tot, a, 0)
        -:math.log2((c + 0.5) / (t + 0.5 * v))
      end)
      |> then(&(Enum.sum(&1) / length(&1)))
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────────
  defp scaled_normal(key, shape, scale) do
    {t, key} = Nx.Random.normal(key, shape: shape)
    {Nx.multiply(t, scale), key}
  end

  defp onehot(ids, v) do
    ids
    |> Enum.map(fn i -> Enum.map(0..(v - 1), fn j -> if j == i, do: 1.0, else: 0.0 end) end)
    |> Nx.tensor()
  end

  defp n_params(v), do: v * @d_x + @d_x * @d_h * 2 + @d_h * v + @d_h * 2 + v
  defp rnd(nil), do: nil
  defp rnd(x), do: Float.round(x, 3)
end
