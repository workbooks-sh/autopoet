defmodule Autopoet.Eval.Replay do
  @moduledoc """
  Eval D2 (wb-q351b.1) — the prequential replay harness, THE go/no-go gate for
  the learning layer.

  Feeds a captured `.etfs` trace (the exact crash-tolerant framed format
  `Autopoet.Capture` writes) through the REAL Hebbian model
  (`Autopoet.Shadow.Hebb.Model`, shared verbatim with the live learner — the
  instrument is the production arithmetic, never a reimplementation) and three
  baselines, scoring every model PREQUENTIALLY: predict the next locus BEFORE
  observing it, then learn it. No labels, no vibes; recomputable from the trace.

  Baselines:
    * uniform   — no information: a fixed first-seen list (chance-level anchor)
    * frequency — decayed global locus counts (what "just popularity" buys)
    * recency   — most-recently-seen loci first (what "just short memory" buys)

  The pre-registered claim (PLAN spike-1 shape): STRUCTURE ≫ NONE — the pathway
  model must beat the frequency baseline on structured traffic. If it cannot on
  real traces, stop widening actuators and diagnose (ladder rung 3).
  """

  alias Autopoet.Shadow.Hebb.Model

  # ── trace IO (Capture's framing, verbatim) ───────────────────────────────────

  @doc "Decode every event frame in an .etfs file; a torn tail frame is skipped."
  def frames(path) do
    case File.read(path) do
      {:ok, bin} -> decode(bin, [])
      _ -> []
    end
  end

  @doc "Write events as an .etfs trace (test fixture generator — same framing Capture writes)."
  def write_trace!(path, events) do
    File.mkdir_p!(Path.dirname(path))

    frames =
      for ev <- events, into: <<>> do
        blob = :erlang.term_to_binary(ev)
        <<byte_size(blob)::32, blob::binary>>
      end

    File.write!(path, frames)
    path
  end

  @doc "The learnable signal stream of a trace: workload events only, mapped to loci (the live learner's exact filter + extraction)."
  def signals(frames) do
    frames
    |> Enum.filter(&Autopoet.Shadow.workload?/1)
    |> Enum.map(&Autopoet.Shadow.signal/1)
  end

  # ── prequential scoring ──────────────────────────────────────────────────────

  # fading factor for the WINDOWED estimate (Gama, Sebastião & Rodrigues, ML 2013:
  # cumulative-from-origin prequential error is provably pessimistic; only the
  # fading/windowed estimate converges to the holdout estimate)
  @fading 0.995

  @doc """
  Score all models over a signal stream. Every transition `prev → next`: each
  model predicts top-`k` from `prev` first, scores a hit if `next` is in it,
  THEN observes. Returns cumulative AND windowed (fading-factor #{@fading})
  hit-rates per model, the hebb miss taxonomy, and a paired hebb−frequency
  block CI (30 blocks, cluster-robust against stream autocorrelation).
  """
  def prequential(signals, k \\ 3)
  def prequential(signals, _k) when length(signals) < 3, do: :not_enough_signal

  def prequential(signals, k) do
    [first | rest] = signals

    init = %{
      hebb: Model.observe(Model.new(), first),
      o2: Autopoet.Eval.Order2.observe(Autopoet.Eval.Order2.new(), first),
      freq: freq_observe(freq_new(), first),
      rec: rec_observe([], first),
      uni: [first],
      seen: MapSet.new([first]),
      hits: %{hebb: 0, o2: 0, freq: 0, rec: 0, uni: 0},
      ff: %{hebb: nil, o2: nil, freq: nil, rec: nil, uni: nil},
      diffs: [],
      misses: %{novel: 0, cold: 0, absent: 0, rank: 0},
      n: 0
    }

    final =
      Enum.reduce(rest, init, fn next, acc ->
        prev = acc.hebb.prev
        hebb_preds = Model.predict(acc.hebb, prev, k)
        hebb_hit = hit(hebb_preds, next)

        h = %{
          hebb: hebb_hit,
          o2: hit(Autopoet.Eval.Order2.predict_next(acc.o2, k), next),
          freq: hit(freq_predict(acc.freq, k), next),
          rec: hit(Enum.take(acc.rec, k), next),
          uni: hit(Enum.take(acc.uni, k), next)
        }

        hits = Map.new(acc.hits, fn {m, v} -> {m, v + h[m]} end)
        ff = Map.new(acc.ff, fn {m, v} -> {m, if(v, do: v + (1 - @fading) * (h[m] - v), else: h[m] / 1)} end)

        # the MISS TAXONOMY — why did the pathway model miss? Each class names
        # its remedy: novel → nothing predicts an unseen locus; cold/absent →
        # the semantic-nominator's territory (embeddings propose, counts elect);
        # rank → η/decay tuning (the select tournament's territory).
        misses =
          if hebb_hit == 1 do
            acc.misses
          else
            class =
              cond do
                not MapSet.member?(acc.seen, next) -> :novel
                hebb_preds == [] -> :cold
                acc.hebb |> Model.decayed_edges(prev) |> List.keymember?(next, 0) -> :rank
                true -> :absent
              end

            Map.update!(acc.misses, class, &(&1 + 1))
          end

        %{
          hebb: Model.observe(acc.hebb, next),
          o2: Autopoet.Eval.Order2.observe(acc.o2, next),
          freq: freq_observe(acc.freq, next),
          rec: rec_observe(acc.rec, next),
          # first-k-seen anchor: storage capped — predictions never take more
          uni: if(length(acc.uni) >= 16 or next in acc.uni, do: acc.uni, else: acc.uni ++ [next]),
          seen: MapSet.put(acc.seen, next),
          hits: hits,
          ff: ff,
          diffs: [h.hebb - h.freq | acc.diffs],
          misses: misses,
          n: acc.n + 1
        }
      end)

    %{
      events: final.n,
      k: k,
      hebb: final.hits.hebb / final.n,
      order2: final.hits.o2 / final.n,
      frequency: final.hits.freq / final.n,
      recency: final.hits.rec / final.n,
      uniform: final.hits.uni / final.n,
      windowed: %{
        hebb: final.ff.hebb,
        order2: final.ff.o2,
        frequency: final.ff.freq,
        recency: final.ff.rec,
        uniform: final.ff.uni
      },
      lift_ci: block_ci(Enum.reverse(final.diffs)),
      misses: final.misses
    }
  end

  # Paired hebb−frequency lift with a cluster-robust 95% CI: the per-event paired
  # differences are split into 30 contiguous blocks (events within a block share
  # trace context — clustering inflates naive SEs), CI over block means.
  defp block_ci(diffs) do
    n = length(diffs)
    blocks = min(30, max(div(n, 10), 1))
    size = max(div(n, blocks), 1)

    means =
      diffs
      |> Enum.chunk_every(size)
      |> Enum.map(fn c -> Enum.sum(c) / length(c) end)

    b = length(means)
    mean = Enum.sum(means) / b

    if b < 3 do
      %{lift: mean, lo: nil, hi: nil, blocks: b}
    else
      var = Enum.sum(for m <- means, do: (m - mean) * (m - mean)) / (b - 1)
      se = :math.sqrt(var / b)
      %{lift: mean, lo: mean - 1.96 * se, hi: mean + 1.96 * se, blocks: b}
    end
  end

  @doc "Prequential scores for a whole .etfs file."
  def score_trace(path, k \\ 3), do: path |> frames() |> signals() |> prequential(k)

  @doc """
  HOLDOUT DISCIPLINE (B3): odd-day traces are holdout, even-day dev. Gates and
  tuning run on dev only; holdout is touched exactly once per pre-registered
  decision (the C4 learning-lift claim). Iterating against the full corpus is
  training-on-test (Kapoor et al. 2024).
  """
  def holdout?(path) do
    case Regex.run(~r/(\d{4})-(\d{2})-(\d{2})/, Path.basename(path)) do
      [_, _y, _m, d] -> rem(String.to_integer(d), 2) == 1
      _ -> false
    end
  end

  defp hit(predictions, actual), do: if(actual in predictions, do: 1, else: 0)

  defp decode(<<size::32, blob::binary-size(size), rest::binary>>, acc) do
    ev =
      try do
        :erlang.binary_to_term(blob)
      rescue
        _ -> nil
      end

    decode(rest, if(is_map(ev), do: [ev | acc], else: acc))
  end

  defp decode(_torn_or_empty, acc), do: Enum.reverse(acc)

  # ── frequency baseline: decayed global counts (same decay as the model, fair) ─
  # O(1) per event: uniform multiplicative decay preserves RANKING, so counts are
  # stored scale-shifted (increment 1/d^t) and only the bumped locus can change
  # rank — a small cached top list stays exact. Periodic renormalization keeps the
  # scale finite. (The naive full-map-decay + full-sort version was O(vocab) per
  # event and timed out on 100k-event production traces — a real harness bug.)

  @freq_top 8
  @freq_rescale 1.0e12

  defp freq_new, do: %{counts: %{}, epoch: 0, t: 0, top: []}

  defp freq_observe(f, sig) do
    d = Model.decay()
    scale = :math.pow(1.0 / d, f.t - f.epoch)

    f =
      if scale > @freq_rescale do
        norm = :math.pow(d, f.t - f.epoch)
        counts = Map.new(f.counts, fn {s, c} -> {s, c * norm} end)
        top = counts |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(@freq_top)
        %{f | counts: counts, epoch: f.t, top: top}
      else
        f
      end

    scale = :math.pow(1.0 / d, f.t - f.epoch)
    c = Map.get(f.counts, sig, 0.0) + scale

    top =
      [{sig, c} | Enum.reject(f.top, fn {s, _} -> s == sig end)]
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.take(@freq_top)

    %{f | counts: Map.put(f.counts, sig, c), t: f.t + 1, top: top}
  end

  defp freq_predict(f, k), do: f.top |> Enum.take(k) |> Enum.map(&elem(&1, 0))

  # ── recency baseline: distinct loci, most recent first (windowed to 32 — exact
  # for any k ≤ 32, O(window) per event instead of O(vocab)) ────────────────────

  defp rec_observe(list, sig), do: [sig | Enum.reject(list, &(&1 == sig))] |> Enum.take(32)
end
