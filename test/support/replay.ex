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

  @doc """
  Score all models over a signal stream. Every transition `prev → next`: each
  model predicts top-`k` from `prev` first, scores a hit if `next` is in it,
  THEN observes. Returns `%{events, k, hebb, frequency, recency, uniform}`
  (hit-rates in [0,1]).
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
      misses: %{novel: 0, cold: 0, absent: 0, rank: 0},
      n: 0
    }

    final =
      Enum.reduce(rest, init, fn next, acc ->
        prev = acc.hebb.prev
        hebb_preds = Model.predict(acc.hebb, prev, k)
        hebb_hit = hit(hebb_preds, next)

        hits = %{
          hebb: acc.hits.hebb + hebb_hit,
          o2: acc.hits.o2 + hit(Autopoet.Eval.Order2.predict_next(acc.o2, k), next),
          freq: acc.hits.freq + hit(freq_predict(acc.freq, k), next),
          rec: acc.hits.rec + hit(Enum.take(acc.rec, k), next),
          uni: acc.hits.uni + hit(Enum.take(acc.uni, k), next)
        }

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
      misses: final.misses
    }
  end

  @doc "Prequential scores for a whole .etfs file."
  def score_trace(path, k \\ 3), do: path |> frames() |> signals() |> prequential(k)

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
