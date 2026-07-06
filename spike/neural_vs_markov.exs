# DECISION-GATING SPIKE — does a tiny self-training minGRU beat the substrate's
# first-order (EMA/Hebbian-class) surprise on HIGHER-ORDER structure?
#
# The substrate's Shadow.Surprise keys on `st.prev` — it is a FIRST-ORDER Markov
# surprise model: P(next | prev). It literally cannot condition on events 2+ back.
# The whole case for a learned recurrent assessor rests on ONE claim: real drift
# sometimes hides in context-conditioned transitions a first-order model is blind
# to. This spike plants exactly such an anomaly and asks whether the RNN catches
# what the baseline cannot — and proves the RNN can SELF-TRAIN online, in-BEAM,
# fast enough to run on the bus.
#
# Honest gate (ICSE "How Far Are We?"): learned must BEAT the simple detector, not
# merely work. If AUROC ties, keep the hand-tuned stack.
#
#   Run: cd autopoet && mix run --no-start spike/neural_vs_markov.exs

Nx.default_backend(EXLA.Backend)
import Nx.Defn

# ── vocabulary: a subset of real substrate loci ──
vocab = ~w(proposal.recorded proposal.accepted proposal.rejected body.wrote
           effect.settled reward.landed treasury.charged treasury.refused
           limb.returned app.executed doc.touch intake.brief)
v = length(vocab)
idx = vocab |> Enum.with_index() |> Map.new()
d_x = 16   # embedding dim
d_h = 32   # hidden dim
win = 12   # truncated window (fixed shape — pin for JIT cache)

# ── synthetic stream generator ──────────────────────────────────────────────
# Normal dynamics: mostly first-order causal chains. THE PLANTED HIGHER-ORDER
# RULE: after the context [proposal.rejected, limb.returned], the correct next
# event is treasury.REFUSED. An ANOMALY is when treasury.CHARGED appears in that
# exact 2-back context. A first-order model sees only `limb.returned -> ?` (both
# charged/refused plausible) and CANNOT flag it; a recurrent model can.
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

# Generate a stream. When `anomalize?` and we're right after [proposal.rejected,
# limb.returned], emit treasury.charged (the anomaly) instead of the lawful
# treasury.refused; record those positions as ground-truth anomalies.
gen = fn n, anomalize? ->
  Enum.reduce(1..n, {["intake.brief"], []}, fn _i, {acc, anom} ->
    [prev | rest] = acc
    prev2 = List.first(rest)
    cond do
      prev == "limb.returned" and prev2 == "proposal.rejected" ->
        # the higher-order decision point
        if anomalize? and :rand.uniform() < 0.5 do
          {["treasury.charged" | acc], [length(acc) | anom]}   # planted anomaly
        else
          {["treasury.refused" | acc], anom}                    # lawful
        end
      true ->
        {[pick.(Map.get(chain, prev, vocab)) | acc], anom}
    end
  end)
  |> then(fn {acc, anom} -> {Enum.reverse(acc), MapSet.new(anom)} end)
end

{train_stream, _} = gen.(4000, false)          # train on NORMAL dynamics only
{test_stream, test_anom} = gen.(1500, true)    # test stream has planted anomalies
ids = fn stream -> Enum.map(stream, &Map.fetch!(idx, &1)) end
train_ids = ids.(train_stream)
test_ids = ids.(test_stream)

# ── minGRU next-event predictor (params in a plain map; forward is a defn) ─────
key = Nx.Random.key(42)
rint = fn key, shape, scale ->
  {t, key} = Nx.Random.normal(key, shape: shape); {Nx.multiply(t, scale), key}
end
{emb, key} = rint.(key, {v, d_x}, 0.1)
{wz, key}  = rint.(key, {d_x, d_h}, 0.2)
{bz, key}  = {Nx.broadcast(0.0, {d_h}), key}
{wh, key}  = rint.(key, {d_x, d_h}, 0.2)
{bh, key}  = {Nx.broadcast(0.0, {d_h}), key}
{wo, key}  = rint.(key, {d_h, v}, 0.2)
{bo, _key} = {Nx.broadcast(0.0, {v}), key}
params = %{emb: emb, wz: wz, bz: bz, wh: wh, bh: bh, wo: wo, bo: bo}

# one-hot [win, v] for a window of ids (avoids gather-grad fiddliness)
onehot = fn id_list ->
  id_list |> Enum.map(fn i -> for j <- 0..(v - 1), do: if(j == i, do: 1.0, else: 0.0) end)
          |> Nx.tensor()
end

# forward over a window: predict tokens 1..win-1 from 0..win-2. Static-unrolled
# (win is compile-time), minGRU recurrence: gates INPUT-ONLY (the key property).
defn logits_seq(p, oh) do
  emb = Nx.dot(oh, p.emb)                       # [win, d_x]
  h0 = Nx.broadcast(0.0, {1, elem(Nx.shape(p.wh), 1)})
  {_h, logits} =
    Enum.reduce(0..(Nx.axis_size(oh, 0) - 2), {h0, []}, fn t, {h, acc} ->
      x = emb[t] |> Nx.reshape({1, :auto})      # [1, d_x]
      z = Nx.sigmoid(Nx.dot(x, p.wz) + p.bz)    # input-only update gate
      c = Nx.dot(x, p.wh) + p.bh                 # input-only candidate
      h = (1.0 - z) * h + z * c                  # linear recurrence
      lg = Nx.dot(h, p.wo) + p.bo                # [1, v]
      {h, [lg | acc]}
    end)
  logits |> Enum.reverse() |> Nx.concatenate(axis: 0)   # [win-1, v]
end

defn loss_fn(p, oh, targets) do
  lg = logits_seq(p, oh)
  logp = lg - Nx.logsumexp(lg, axes: [1], keep_axes: true)
  # cross-entropy of the actual next token at each step
  Nx.mean(-Nx.sum(targets * logp, axes: [1]))
end

# per-window surprise = same CE (this is the anomaly score the substrate would read)
defn window_surprise(p, oh, targets) do
  lg = logits_seq(p, oh)
  logp = lg - Nx.logsumexp(lg, axes: [1], keep_axes: true)
  -Nx.sum(targets * logp, axes: [1])            # [win-1] per-step surprise
end

{init_opt, opt_update} = Polaris.Optimizers.adam(learning_rate: 5.0e-3)
opt_state = init_opt.(params)

# window helpers
windows = fn id_list -> id_list |> Enum.chunk_every(win, 1, :discard) end
targets_of = fn win_ids -> win_ids |> Enum.drop(1) |> onehot.() end   # [win-1, v]

train_step = fn p, os, oh, tg ->
  {loss, grads} = Nx.Defn.value_and_grad(p, &loss_fn(&1, oh, tg))
  {updates, os} = opt_update.(grads, os, p)
  {Polaris.Updates.apply_updates(p, updates), os, loss}
end

IO.puts("\n#### self-training minGRU vs first-order Markov — substrate anomaly gate ####")
IO.puts("vocab=#{v}  d_x=#{d_x}  d_h=#{d_h}  win=#{win}  params≈#{v*d_x + d_x*d_h*2 + d_h*v + d_h*2 + v}")

# ── ONLINE training: one Adam step per sliding window, streamed once ──
train_wins = windows.(train_ids)
t0 = System.monotonic_time(:microsecond)
{params, _opt_state, losses} =
  train_wins
  |> Enum.reduce({params, opt_state, []}, fn w, {p, os, ls} ->
    oh = onehot.(w); tg = targets_of.(w)
    {p, os, loss} = train_step.(p, os, oh, tg)
    {p, os, [Nx.to_number(loss) | ls]}
  end)
dt = System.monotonic_time(:microsecond) - t0
n_steps = length(train_wins)
first10 = losses |> Enum.reverse() |> Enum.take(10) |> Enum.map(&Float.round(&1, 2))
last10  = losses |> Enum.take(10) |> Enum.map(&Float.round(&1, 2))
IO.puts("trained #{n_steps} online steps in #{Float.round(dt/1000,1)}ms  (#{Float.round(dt/n_steps,0)}µs/step)")
IO.puts("loss  first10=#{inspect(first10)}\n      last10 =#{inspect(last10)}")

# ── first-order Markov baseline (mirrors Shadow.Surprise: P(next|prev)) ──
counts =
  train_ids |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce(%{}, fn [a, b], m -> Map.update(m, {a, b}, 1, &(&1 + 1)) end)
tot = train_ids |> Enum.chunk_every(2, 1, :discard)
  |> Enum.reduce(%{}, fn [a, _], m -> Map.update(m, a, 1, &(&1 + 1)) end)
markov_surprise = fn prev, nxt ->
  c = Map.get(counts, {prev, nxt}, 0); t = Map.get(tot, prev, 0)
  p = (c + 0.5) / (t + 0.5 * v)                # add-0.5 smoothing
  -:math.log2(p)
end

# ── EVAL: score every test position; is it an anomaly? compare separation ──
# For each position i (>= win), the NEURAL score = surprise at the last step of
# the window ending at i; the MARKOV score = -log P(id_i | id_{i-1}).
test_wins_idx = win..(length(test_ids) - 1)
{neural_scores, markov_scores, labels} =
  Enum.reduce(test_wins_idx, {[], [], []}, fn i, {ns, ms, ls} ->
    w = Enum.slice(test_ids, (i - win + 1)..i)
    oh = onehot.(w); tg = targets_of.(w)
    neural = window_surprise(params, oh, tg) |> then(&Nx.to_number(&1[win - 2]))
    prev = Enum.at(test_ids, i - 1); nxt = Enum.at(test_ids, i)
    markov = markov_surprise.(prev, nxt)
    label = if MapSet.member?(test_anom, i), do: 1, else: 0
    {[neural | ns], [markov | ms], [label | ls]}
  end)

# exact AUROC = P(score(anomaly) > score(normal)) over all pairs
auroc = fn scores, labels ->
  pairs = Enum.zip(scores, labels)
  pos = for {s, 1} <- pairs, do: s
  neg = for {s, 0} <- pairs, do: s
  if pos == [] or neg == [] do
    :no_anomalies
  else
    wins = for p <- pos, n <- neg, reduce: 0.0 do acc ->
      acc + cond do p > n -> 1.0; p == n -> 0.5; true -> 0.0 end
    end
    wins / (length(pos) * length(neg))
  end
end

n_anom = Enum.count(labels, &(&1 == 1))
IO.puts("\ntest positions=#{length(labels)}  planted higher-order anomalies=#{n_anom}")
neural_auroc = auroc.(neural_scores, labels)
markov_auroc = auroc.(markov_scores, labels)
r3 = fn x -> if is_number(x), do: Float.round(x, 3), else: x end
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
