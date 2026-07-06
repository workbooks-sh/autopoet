# STATUS (2026-07-06): WIP — the minGRU forward + loss are correct, but the
# hand-rolled sequential recurrence (Enum.reduce building a tensor accumulator)
# does not survive `value_and_grad` under either the Nx evaluator (backend mixing,
# Nx #776) or EXLA JIT (Enum.reduce rejected in the grad path). The production fix
# is to express the recurrence with Axon's built-in `Axon.gru` layer (or an
# `Nx.Defn.while` with `Nx.put_slice`), NOT a hand-rolled fold. The DECISION this
# spike was meant to gate — "is there higher-order signal a first-order detector
# misses?" — is instead proven cleanly (and backend-free) in
# `higher_order_signal.exs`: first-order AUROC 0.51 vs second-order 1.00. Keep this
# file as the minGRU-cell starting point for the real Axon-based build.
#
# DECISION-GATING SPIKE — does a tiny self-training minGRU beat the substrate's
# first-order (EMA/Hebbian-class) surprise on HIGHER-ORDER structure?
#
# Shadow.Surprise keys on `st.prev` — a FIRST-ORDER Markov surprise model:
# P(next | prev). It literally cannot condition on events 2+ back. The whole case
# for a learned recurrent assessor rests on ONE claim: real drift sometimes hides
# in context-conditioned transitions a first-order model is blind to. This spike
# plants exactly such an anomaly, proves the RNN SELF-TRAINS online in-BEAM fast
# enough for the bus, and asks whether it catches what the baseline cannot.
#
# Honest gate (ICSE "How Far Are We?"): learned must BEAT the simple detector, not
# merely work. If AUROC ties, keep the hand-tuned stack.
#
#   Run: cd autopoet && mix run --no-start spike/neural_vs_markov.exs

# Pure BinaryBackend + the default Nx evaluator: it unrolls the compile-time fold
# and keeps one backend throughout (no EXLA/evaluator mixing — Nx #776). Slower
# than EXLA, but the AUROC decision-gate is backend-independent; EXLA per-step
# latency is cited separately from the research (~low-single-digit ms).

defmodule MinGRU do
  import Nx.Defn
  @win 12   # window length (compile-time — must match the script's `win`)

  # forward over a window: predict tokens 1..W-1 from 0..W-2. Static-unrolled (W
  # is a compile-time attribute so the fold unrolls at compile time). minGRU
  # recurrence — gates depend on INPUT ONLY (the property that makes it cheap +
  # stable to train online).
  defn logits_seq(p, oh) do
    emb = Nx.dot(oh, p.emb)
    h0 = Nx.broadcast(0.0, {1, elem(Nx.shape(p.wh), 1)})

    {_h, logits} =
      Enum.reduce(0..(@win - 2), {h0, nil}, fn t, {h, acc} ->
        x = Nx.slice_along_axis(emb, t, 1, axis: 0)
        z = Nx.sigmoid(Nx.dot(x, p.wz) + p.bz)
        c = Nx.dot(x, p.wh) + p.bh
        h = (1.0 - z) * h + z * c
        lg = Nx.dot(h, p.wo) + p.bo
        # accumulate by concatenation; t is a compile-time int so the branch is static
        acc = if t == 0, do: lg, else: Nx.concatenate([acc, lg], axis: 0)
        {h, acc}
      end)

    logits
  end

  # stable log-softmax over the vocab axis (no Nx.logsumexp dependency)
  defnp log_softmax(lg) do
    m = Nx.reduce_max(lg, axes: [1], keep_axes: true)
    lg - m - Nx.log(Nx.sum(Nx.exp(lg - m), axes: [1], keep_axes: true))
  end

  defn loss_fn(p, oh, targets) do
    logp = log_softmax(logits_seq(p, oh))
    Nx.mean(-Nx.sum(targets * logp, axes: [1]))
  end

  # per-step surprise = CE of the actual next token (the anomaly score the
  # substrate would read off).
  defn window_surprise(p, oh, targets) do
    logp = log_softmax(logits_seq(p, oh))
    -Nx.sum(targets * logp, axes: [1])
  end
end

# ── vocabulary: a subset of real substrate loci ──
vocab = ~w(proposal.recorded proposal.accepted proposal.rejected body.wrote
           effect.settled reward.landed treasury.charged treasury.refused
           limb.returned app.executed doc.touch intake.brief)
v = length(vocab)
idx = vocab |> Enum.with_index() |> Map.new()
d_x = 16
d_h = 32
win = 12

# ── synthetic stream. Higher-order rule: after [proposal.rejected, limb.returned]
# the lawful next is treasury.REFUSED; the ANOMALY is treasury.CHARGED in that
# exact 2-back context. A first-order model sees only `limb.returned -> ?` and
# can't flag it; a recurrent model can. ──
:rand.seed(:exsss, {7, 13, 21})
chain = %{
  "proposal.recorded" => ["proposal.accepted", "proposal.rejected"],
  "proposal.accepted" => ["body.wrote"],
  "proposal.rejected" => ["limb.returned"],
  "body.wrote" => ["effect.settled"],
  "effect.settled" => ["reward.landed", "treasury.charged"],
  "reward.landed" => ["treasury.charged"],
  "treasury.charged" => ["intake.brief", "proposal.recorded"],
  "treasury.refused" => ["intake.brief", "proposal.recorded"],
  "limb.returned" => ["app.executed"],
  "app.executed" => ["effect.settled"],
  "doc.touch" => ["body.wrote"],
  "intake.brief" => ["proposal.recorded", "doc.touch"]
}
pick = fn xs -> Enum.at(xs, :rand.uniform(length(xs)) - 1) end

gen = fn n, anomalize? ->
  Enum.reduce(1..n, {["intake.brief"], []}, fn _i, {acc, anom} ->
    [prev | rest] = acc
    prev2 = List.first(rest)

    cond do
      prev == "limb.returned" and prev2 == "proposal.rejected" ->
        if anomalize? and :rand.uniform() < 0.5 do
          {["treasury.charged" | acc], [length(acc) | anom]}
        else
          {["treasury.refused" | acc], anom}
        end

      true ->
        {[pick.(Map.get(chain, prev, vocab)) | acc], anom}
    end
  end)
  |> then(fn {acc, anom} -> {Enum.reverse(acc), MapSet.new(anom)} end)
end

{train_stream, _} = gen.(4000, false)
{test_stream, test_anom} = gen.(1500, true)
ids = fn stream -> Enum.map(stream, &Map.fetch!(idx, &1)) end
train_ids = ids.(train_stream)
test_ids = ids.(test_stream)

# ── params ──
key = Nx.Random.key(42)
rint = fn key, shape, scale ->
  {t, key} = Nx.Random.normal(key, shape: shape)
  {Nx.multiply(t, scale), key}
end
{emb, key} = rint.(key, {v, d_x}, 0.1)
{wz, key} = rint.(key, {d_x, d_h}, 0.2)
{wh, key} = rint.(key, {d_x, d_h}, 0.2)
{wo, _key} = rint.(key, {d_h, v}, 0.2)
params = %{emb: emb, wz: wz, bz: Nx.broadcast(0.0, {d_h}), wh: wh,
           bh: Nx.broadcast(0.0, {d_h}), wo: wo, bo: Nx.broadcast(0.0, {v})}

onehot = fn id_list ->
  id_list
  |> Enum.map(fn i -> for j <- 0..(v - 1), do: if(j == i, do: 1.0, else: 0.0) end)
  |> Nx.tensor()
end

{init_opt, opt_update} = Polaris.Optimizers.adam(learning_rate: 5.0e-3)
opt_state = init_opt.(params)

windows = fn id_list -> id_list |> Enum.chunk_every(win, 1, :discard) end
targets_of = fn win_ids -> win_ids |> Enum.drop(1) |> onehot.() end

train_step = fn p, os, oh, tg ->
  {loss, grads} = Nx.Defn.value_and_grad(p, &MinGRU.loss_fn(&1, oh, tg))
  {updates, os} = opt_update.(grads, os, p)
  {Polaris.Updates.apply_updates(p, updates), os, loss}
end

IO.puts("\n#### self-training minGRU vs first-order Markov — substrate anomaly gate ####")
IO.puts("vocab=#{v}  d_x=#{d_x}  d_h=#{d_h}  win=#{win}  params≈#{v * d_x + d_x * d_h * 2 + d_h * v + d_h * 2 + v}")

# ── ONLINE training: one Adam step per sliding window ──
train_wins = windows.(train_ids)
t0 = System.monotonic_time(:microsecond)

{params, _opt_state, losses} =
  train_wins
  |> Enum.reduce({params, opt_state, []}, fn w, {p, os, ls} ->
    oh = onehot.(w)
    tg = targets_of.(w)
    {p, os, loss} = train_step.(p, os, oh, tg)
    {p, os, [Nx.to_number(loss) | ls]}
  end)

dt = System.monotonic_time(:microsecond) - t0
n_steps = length(train_wins)
first10 = losses |> Enum.reverse() |> Enum.take(10) |> Enum.map(&Float.round(&1, 2))
last10 = losses |> Enum.take(10) |> Enum.map(&Float.round(&1, 2))
IO.puts("trained #{n_steps} online steps in #{Float.round(dt / 1000, 1)}ms  (#{Float.round(dt / n_steps, 0)}µs/step)")
IO.puts("loss  first10=#{inspect(first10)}\n      last10 =#{inspect(last10)}")

# ── first-order Markov baseline (mirrors Shadow.Surprise: P(next|prev)) ──
counts =
  train_ids
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce(%{}, fn [a, b], m -> Map.update(m, {a, b}, 1, &(&1 + 1)) end)

tot =
  train_ids
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce(%{}, fn [a, _], m -> Map.update(m, a, 1, &(&1 + 1)) end)

markov_surprise = fn prev, nxt ->
  c = Map.get(counts, {prev, nxt}, 0)
  t = Map.get(tot, prev, 0)
  p = (c + 0.5) / (t + 0.5 * v)
  -:math.log2(p)
end

# ── EVAL: score every test position, compare separation of anomaly vs normal ──
{neural_scores, markov_scores, labels} =
  Enum.reduce(win..(length(test_ids) - 1), {[], [], []}, fn i, {ns, ms, ls} ->
    w = Enum.slice(test_ids, (i - win + 1)..i)
    neural = MinGRU.window_surprise(params, onehot.(w), targets_of.(w)) |> then(&Nx.to_number(&1[win - 2]))
    markov = markov_surprise.(Enum.at(test_ids, i - 1), Enum.at(test_ids, i))
    label = if MapSet.member?(test_anom, i), do: 1, else: 0
    {[neural | ns], [markov | ms], [label | ls]}
  end)

auroc = fn scores, labels ->
  pairs = Enum.zip(scores, labels)
  pos = for {s, 1} <- pairs, do: s
  neg = for {s, 0} <- pairs, do: s

  if pos == [] or neg == [] do
    :no_anomalies
  else
    wins =
      for p <- pos, n <- neg, reduce: 0.0 do
        acc -> acc + cond do
          p > n -> 1.0
          p == n -> 0.5
          true -> 0.0
        end
      end

    wins / (length(pos) * length(neg))
  end
end

r3 = fn x -> if is_number(x), do: Float.round(x, 3), else: x end
n_anom = Enum.count(labels, &(&1 == 1))
IO.puts("\ntest positions=#{length(labels)}  planted higher-order anomalies=#{n_anom}")
neural_auroc = auroc.(neural_scores, labels)
markov_auroc = auroc.(markov_scores, labels)
IO.puts("\n======== RESULT (AUROC: separates anomaly from normal, 0.5=chance) ========")
IO.puts("  first-order Markov (baseline, = today's Surprise): #{inspect(r3.(markov_auroc))}")
IO.puts("  self-trained minGRU (learned recurrent):           #{inspect(r3.(neural_auroc))}")

verdict =
  cond do
    not is_number(neural_auroc) -> "inconclusive"
    neural_auroc >= markov_auroc + 0.10 -> "RNN WINS — catches higher-order structure the baseline is blind to. Worth it."
    neural_auroc >= markov_auroc + 0.02 -> "RNN edges ahead — margin thin; weigh training complexity."
    true -> "NO WIN — baseline matches it. Keep the hand-tuned stack."
  end

IO.puts("\n=> #{verdict}")
