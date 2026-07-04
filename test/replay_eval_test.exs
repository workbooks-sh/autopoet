defmodule Autopoet.ReplayEvalTest do
  @moduledoc """
  Eval D2 (wb-q351b.1) — prequential replay: the go/no-go gate for the learning
  layer, scored on the REAL model arithmetic over Capture-format traces.

  PRE-REGISTERED GATES (committed before outcomes, per the PLAN's discipline):
    G-STRUCT  on structured persona traffic (10% noise), hebb top-3 hit-rate
              must beat the frequency baseline by ≥ 0.10 absolute.
    G-DRIFT   after an abrupt full-vocabulary shift mid-trace, hebb must still
              beat frequency overall (decay adapts, popularity lags).
    G-DETERM  identical trace → identical scores (pure instrument, replayable).

  Production traces present under data/traces are scored and PRINTED
  (informational — content unknown a priori, no hard gate; alarms are
  investigation leads, silence certifies nothing).
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{Personas, Replay}

  defp tmp_trace(name, events) do
    dir = Path.join(System.tmp_dir!(), "ap_replay_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    Replay.write_trace!(Path.join(dir, name), events)
  end

  # structured world: the six personas' pulses cycling, salted with noise events
  defp structured_events(rounds, noise_pct, salt \\ {7, 7, 7}) do
    :rand.seed(:exsss, salt)

    for _ <- 1..rounds, p <- Personas.all(), ev <- p.pulse do
      if :rand.uniform(100) <= noise_pct do
        %{kind: "noise.event", doc: "noise-#{:rand.uniform(30)}", tags: []}
      else
        Map.put(ev, :tags, [])
      end
    end
  end

  # pass^k discipline (tau-bench): the gate holds on EVERY seed, not the best one
  @gate_seeds [{7, 7, 7}, {101, 3, 9}, {42, 42, 1}]

  test "G-STRUCT (pass^3 + CI): structure ≫ popularity on every seed, lift CI excludes zero" do
    results =
      for salt <- @gate_seeds do
        path = tmp_trace("structured-#{elem(salt, 0)}.etfs", structured_events(40, 10, salt))
        scores = Replay.score_trace(path)

        assert scores.hebb > scores.frequency + 0.10,
               "GATE G-STRUCT FAILED (seed #{inspect(salt)}): hebb #{fmt(scores.hebb)} vs " <>
                 "frequency #{fmt(scores.frequency)} — learning adds nothing over popularity"

        assert scores.lift_ci.lo > 0,
               "GATE G-STRUCT FAILED (seed #{inspect(salt)}): 95% CI on hebb−frequency lift " <>
                 "includes zero (#{inspect(scores.lift_ci)}) — a coin flip, not a result"

        assert scores.hebb > scores.uniform
        scores
      end

    s = hd(results)

    IO.puts(
      "  ✓ EVAL replay/structured (pass^#{length(results)}, n=#{s.events}/seed, k=#{s.k}) — " <>
        "hebb #{fmt(s.hebb)} (windowed #{fmt(s.windowed.hebb)}) · frequency #{fmt(s.frequency)} · " <>
        "lift CI [#{fmt(s.lift_ci.lo)}, #{fmt(s.lift_ci.hi)}] over #{s.lift_ci.blocks} blocks · " <>
        "recency #{fmt(s.recency)} · uniform #{fmt(s.uniform)}"
    )

    Autopoet.Eval.History.record("replay/structured", %{
      seeds_passed: length(results),
      hebb: s.hebb,
      hebb_windowed: s.windowed.hebb,
      order2: s.order2,
      frequency: s.frequency,
      lift_lo: s.lift_ci.lo,
      lift_hi: s.lift_ci.hi,
      events: s.events,
      k: s.k
    })
  end

  test "G-DRIFT: hebb adapts across an abrupt regime shift; frequency lags" do
    :rand.seed(:exsss, {11, 11, 11})

    regime_a = structured_events(20, 5)

    regime_b =
      for _ <- 1..20, p <- Personas.all(), ev <- p.pulse do
        sig = to_string(ev[:doc] || ev[:target] || ev[:kind])
        %{kind: "doc.touch", doc: "v2/#{sig}", tags: []}
      end

    path = tmp_trace("drift.etfs", regime_a ++ regime_b)
    scores = Replay.score_trace(path)

    IO.puts(
      "  ✓ EVAL replay/drift (n=#{scores.events}) — hebb #{fmt(scores.hebb)} " <>
        "(windowed #{fmt(scores.windowed.hebb)} — post-drift recovery visible) · " <>
        "frequency #{fmt(scores.frequency)} · recency #{fmt(scores.recency)}"
    )

    Autopoet.Eval.History.record("replay/drift", %{
      hebb: scores.hebb,
      hebb_windowed: scores.windowed.hebb,
      order2: scores.order2,
      frequency: scores.frequency,
      events: scores.events
    })

    assert scores.hebb > scores.frequency,
           "GATE G-DRIFT FAILED: hebb #{fmt(scores.hebb)} ≤ frequency #{fmt(scores.frequency)} after drift"
  end

  test "G-DETERM: the instrument is pure — identical trace, identical scores" do
    events = structured_events(10, 10)
    path = tmp_trace("determ.etfs", events)

    assert Replay.score_trace(path) == Replay.score_trace(path)
  end

  test "trace IO: torn tail frame is skipped, never crashes (Capture's crash tolerance)" do
    path = tmp_trace("torn.etfs", structured_events(2, 0))
    whole = Replay.frames(path) |> length()
    assert whole > 0

    # tear the last frame mid-blob
    bin = File.read!(path)
    File.write!(path, binary_part(bin, 0, byte_size(bin) - 3))
    torn = Replay.frames(path) |> length()
    assert torn == whole - 1
  end

  # accumulated day-traces run to 100k+ events; the informational sweep scores a
  # bounded window and SAYS so (no silent caps)
  @info_cap 25_000

  test "production traces (informational): score whatever the capture layer has recorded" do
    traces = Path.wildcard(Path.join(Autopoet.Capture.dir(), "*.etfs"))

    for path <- Enum.take(traces, 3) do
      case path |> Replay.frames() |> Enum.take(@info_cap) |> Replay.signals() |> Replay.prequential() do
        :not_enough_signal ->
          IO.puts("  · EVAL replay/#{Path.basename(path)} — not enough signal")

        s ->
          m = s.misses
          total_miss = max(m.novel + m.cold + m.absent + m.rank, 1)
          split = if Replay.holdout?(path), do: "HOLDOUT", else: "dev"

          IO.puts(
            "  · EVAL replay/#{Path.basename(path)} [#{split}] (n=#{s.events}, first #{@info_cap} frames) — hebb #{fmt(s.hebb)} · " <>
              "ORDER2 #{fmt(s.order2)} · frequency #{fmt(s.frequency)} · recency #{fmt(s.recency)} · uniform #{fmt(s.uniform)}\n" <>
              "      misses: novel #{pct(m.novel, total_miss)} · cold #{pct(m.cold, total_miss)} · " <>
              "absent #{pct(m.absent, total_miss)} (semantic territory) · rank #{pct(m.rank, total_miss)} (tuning territory)"
          )

          Autopoet.Eval.History.record("replay/trace-#{Path.basename(path, ".etfs")}-#{if Replay.holdout?(path), do: "holdout", else: "dev"}", %{
            hebb: s.hebb,
            hebb_windowed: s.windowed.hebb,
            order2: s.order2,
            frequency: s.frequency,
            recency: s.recency,
            lift_lo: s.lift_ci.lo || 0.0,
            lift_hi: s.lift_ci.hi || 0.0,
            miss_rank: s.misses.rank,
            miss_semantic: s.misses.cold + s.misses.absent,
            miss_novel: s.misses.novel,
            events: s.events
          })
      end
    end

    assert is_list(traces)
  end

  defp fmt(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
  defp pct(n, d), do: :erlang.float_to_binary(n * 100 / d, decimals: 0) <> "%"
end
