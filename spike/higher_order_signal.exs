# DECISION-GATE (the honest core question): does the substrate's event stream
# contain HIGHER-ORDER structure that a first-order detector — today's
# Shadow.Surprise, which keys on `st.prev` alone — is BLIND to?
#
# This is the necessary precondition for a learned recurrent assessor (minGRU) to
# be worth building. The minGRU is just the LEARNED, GENERALIZING version of a
# history-conditioned model; if even an explicit k-order Markov model can't beat
# first-order on the planted anomaly, no RNN will, and we keep the hand-tuned
# stack (ICSE "How Far Are We?" — learned must BEAT simple, not merely work).
#
# Pure Elixir (no Nx) so the result is airtight and instant. It isolates ONE
# variable: how much history the predictor conditions on (Markov order k).
#
#   Run: cd autopoet && mix run --no-start spike/higher_order_signal.exs

vocab = ~w(proposal.recorded proposal.accepted proposal.rejected body.wrote
           effect.settled reward.landed treasury.charged treasury.refused
           limb.returned app.executed doc.touch intake.brief)
v = length(vocab)

# PLANTED higher-order rule, designed so first-order is genuinely BLIND:
#   * `limb.returned` is reached from MANY predecessors and NORMALLY leads to
#     `treasury.charged` (~70%) — so `limb.returned -> treasury.charged` is a
#     COMMON first-order transition, NOT surprising on its own.
#   * BUT after the 2-back context [proposal.rejected, limb.returned] the lawful
#     next is `treasury.REFUSED`. The ANOMALY is `treasury.charged` in THAT
#     context. First-order can't see it (charged-after-limb is normal overall);
#     only a >=2nd-order model catches it.
:rand.seed(:exsss, {7, 13, 21})
chain = %{
  "proposal.recorded" => ["proposal.accepted", "proposal.rejected"],
  "proposal.accepted" => ["body.wrote"],
  "proposal.rejected" => ["limb.returned"],
  "body.wrote" => ["effect.settled", "limb.returned"],
  "effect.settled" => ["reward.landed", "limb.returned", "treasury.charged"],
  "reward.landed" => ["treasury.charged"],
  "treasury.charged" => ["intake.brief", "proposal.recorded", "app.executed"],
  "treasury.refused" => ["intake.brief", "proposal.recorded"],
  "app.executed" => ["limb.returned", "doc.touch"],
  "doc.touch" => ["body.wrote", "app.executed"],
  "intake.brief" => ["proposal.recorded", "doc.touch"]
}
pick = fn xs -> Enum.at(xs, :rand.uniform(length(xs)) - 1) end

# limb.returned's successor: lawful treasury.REFUSED after a proposal.rejected
# 2-back, else the COMMON treasury.charged (70%) / app.executed (30%).
gen = fn n, anomalize? ->
  {rev, anom} =
    Enum.reduce(1..n, {["intake.brief"], []}, fn _i, {acc, anom} ->
      [prev | rest] = acc
      prev2 = List.first(rest)

      cond do
        prev == "limb.returned" and prev2 == "proposal.rejected" ->
          # the higher-order decision point: lawful = refused; anomaly = charged
          if anomalize? and :rand.uniform() < 0.5,
            do: {["treasury.charged" | acc], [length(acc) | anom]},
            else: {["treasury.refused" | acc], anom}

        prev == "limb.returned" ->
          # general context: charged is the COMMON outcome (makes it 1st-order-normal)
          nxt = if :rand.uniform() < 0.7, do: "treasury.charged", else: "app.executed"
          {[nxt | acc], anom}

        true ->
          {[pick.(Map.get(chain, prev, vocab)) | acc], anom}
      end
    end)

  {Enum.reverse(rev), MapSet.new(anom)}
end

{train, _} = gen.(6000, false)
{test, test_anom} = gen.(2000, true)

# k-order Markov surprise model: P(next | previous k events), add-α smoothed.
# k=1 is EXACTLY the substrate's current first-order Surprise detector.
build = fn stream, k ->
  stream
  |> Enum.chunk_every(k + 1, 1, :discard)
  |> Enum.reduce({%{}, %{}}, fn chunk, {joint, ctx} ->
    context = Enum.take(chunk, k)
    nxt = List.last(chunk)
    {Map.update(joint, {context, nxt}, 1, &(&1 + 1)), Map.update(ctx, context, 1, &(&1 + 1))}
  end)
end

surprise = fn {joint, ctx}, context, nxt ->
  c = Map.get(joint, {context, nxt}, 0)
  t = Map.get(ctx, context, 0)
  p = (c + 0.5) / (t + 0.5 * v)
  -:math.log2(p)
end

# exact AUROC = P(score(anomaly) > score(normal)) over all pairs
auroc = fn scored ->
  pos = for {s, 1} <- scored, do: s
  neg = for {s, 0} <- scored, do: s
  wins =
    for p <- pos, n <- neg, reduce: 0.0 do
      acc -> acc + cond do
        p > n -> 1.0
        p == n -> 0.5
        true -> 0.0
      end
    end
  {wins / (length(pos) * length(neg)), length(pos), length(neg)}
end

test_arr = List.to_tuple(test)

score_order = fn k ->
  model = build.(train, k)
  scored =
    for i <- k..(tuple_size(test_arr) - 1) do
      context = for j <- (i - k)..(i - 1), do: elem(test_arr, j)
      nxt = elem(test_arr, i)
      label = if MapSet.member?(test_anom, i), do: 1, else: 0
      {surprise.(model, context, nxt), label}
    end
  auroc.(scored)
end

IO.puts("\n#### higher-order signal gate — k-order Markov on planted 2-back anomaly ####")
IO.puts("vocab=#{v}  train=#{length(train)}  test=#{length(test)}")
IO.puts("\n  order k | AUROC (anomaly vs normal) | note")
IO.puts(String.duplicate("-", 60))

results =
  for k <- 1..3 do
    {a, npos, _nneg} = score_order.(k)
    note = case k do
      1 -> "= today's Shadow.Surprise (first-order)"
      2 -> "conditions on the 2-back context — the planted rule"
      3 -> "more history (diminishing return expected)"
    end
    :io.format("     ~w   | ~-25.3f | ~s~n", [k, a, note])
    {k, a, npos}
  end

{_, a1, npos} = Enum.find(results, fn {k, _, _} -> k == 1 end)
{_, a2, _} = Enum.find(results, fn {k, _, _} -> k == 2 end)
IO.puts(String.duplicate("-", 60))
IO.puts("planted anomalies in test: #{npos}")
IO.puts("\n======== VERDICT ========")
gain = a2 - a1
:io.format("first-order AUROC=~.3f   second-order AUROC=~.3f   gain=+~.3f~n", [a1, a2, gain])

cond do
  a1 >= 0.6 ->
    IO.puts("=> First-order ALREADY catches it — no higher-order signal here. The RNN")
    IO.puts("   wouldn't earn its place on this anomaly. Keep the hand-tuned stack.")

  gain >= 0.2 ->
    IO.puts("=> CONFIRMED: higher-order structure exists and first-order is BLIND to it")
    IO.puts("   (near-chance), while conditioning on history separates it cleanly. This")
    IO.puts("   is the signal a learned recurrent assessor (minGRU) would generalize —")
    IO.puts("   the RNN direction is justified WHERE this kind of structure is real.")

  true ->
    IO.puts("=> Weak/ambiguous higher-order gain — RNN payoff uncertain; needs real traces.")
end
