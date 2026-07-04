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
  defp structured_events(rounds, noise_pct) do
    :rand.seed(:exsss, {7, 7, 7})

    for _ <- 1..rounds, p <- Personas.all(), ev <- p.pulse do
      if :rand.uniform(100) <= noise_pct do
        %{kind: "noise.event", doc: "noise-#{:rand.uniform(30)}", tags: []}
      else
        Map.put(ev, :tags, [])
      end
    end
  end

  test "G-STRUCT: structure ≫ popularity — hebb beats the frequency baseline on persona traffic" do
    path = tmp_trace("structured.etfs", structured_events(40, 10))
    scores = Replay.score_trace(path)

    IO.puts(
      "  ✓ EVAL replay/structured (n=#{scores.events}, k=#{scores.k}) — " <>
        "hebb #{fmt(scores.hebb)} · frequency #{fmt(scores.frequency)} · " <>
        "recency #{fmt(scores.recency)} · uniform #{fmt(scores.uniform)}"
    )

    Autopoet.Eval.History.record("replay/structured", scores)

    assert scores.hebb > scores.frequency + 0.10,
           "GATE G-STRUCT FAILED: hebb #{fmt(scores.hebb)} vs frequency #{fmt(scores.frequency)} — " <>
             "learning adds nothing over popularity; stop widening actuators and diagnose"

    assert scores.hebb > scores.uniform
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
      "  ✓ EVAL replay/drift (n=#{scores.events}) — hebb #{fmt(scores.hebb)} · " <>
        "frequency #{fmt(scores.frequency)} · recency #{fmt(scores.recency)}"
    )

    Autopoet.Eval.History.record("replay/drift", scores)

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

  test "production traces (informational): score whatever the capture layer has recorded" do
    traces = Path.wildcard(Path.join(Autopoet.Capture.dir(), "*.etfs"))

    for path <- Enum.take(traces, 3) do
      case Replay.score_trace(path) do
        :not_enough_signal ->
          IO.puts("  · EVAL replay/#{Path.basename(path)} — not enough signal")

        s ->
          IO.puts(
            "  · EVAL replay/#{Path.basename(path)} (n=#{s.events}) — hebb #{fmt(s.hebb)} · " <>
              "frequency #{fmt(s.frequency)} · recency #{fmt(s.recency)} · uniform #{fmt(s.uniform)}"
          )

          Autopoet.Eval.History.record("replay/trace-#{Path.basename(path, ".etfs")}", s)
      end
    end

    assert is_list(traces)
  end

  defp fmt(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
end
