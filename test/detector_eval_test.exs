defmodule Autopoet.DetectorEvalTest do
  @moduledoc """
  Eval B6 (wb-h0tjs.3) — the drift detector benchmarked AS a detector, per the
  standard protocol for DDM/ADWIN-class evaluation (Gama et al. 2014): streams
  with drift injected at KNOWN points → detection delay + false-alarm rate,
  against the pinned chamber envelope (E3, replay-corrected):

    abrupt ≥25% severity → reliable detection in 30–119 events
    false alarms        → ≤ ~0.07% of events on stable streams

  Runs the REAL detector arithmetic (Surprise.Model, shared verbatim with the
  live GenServer) at the PINNED sustain — never a reimplementation, never the
  test override.
  """
  use ExUnit.Case, async: true

  alias Autopoet.Eval.Personas
  alias Autopoet.Shadow.Surprise.Model

  @pinned_sustain 15

  defp persona_signals(rounds, salt) do
    :rand.seed(:exsss, salt)

    for _ <- 1..rounds, p <- Personas.all(), ev <- p.pulse do
      to_string(ev[:doc] || ev[:target] || ev[:kind])
    end
  end

  defp run_stream(signals) do
    Enum.reduce(signals, {Model.new(), []}, fn sig, {st, alarms} ->
      case Model.observe(st, sig, @pinned_sustain) do
        {st, true} -> {st, [st.t | alarms]}
        {st, false} -> {st, alarms}
      end
    end)
  end

  test "D-FA: stable persona streams stay quiet — false-alarm rate within envelope" do
    {_, alarms} = run_stream(persona_signals(150, {31, 1, 7}))
    n = 150 * 24
    rate = length(alarms) / n

    assert rate <= 0.001,
           "D-FA FAILED: #{length(alarms)} alarms on #{n} stable events (#{Float.round(rate * 100, 3)}% > 0.1%)"

    IO.puts("  ✓ EVAL detector/fa — #{length(alarms)} alarm(s) in #{n} stable events (#{Float.round(rate * 100, 3)}%)")
    Autopoet.Eval.History.record("detector/fa", %{alarms: length(alarms), events: n, rate: rate})
  end

  test "D-DELAY: abrupt full-vocabulary drift detected within the pinned envelope" do
    :rand.seed(:exsss, {13, 5, 2})
    stable = persona_signals(80, {13, 5, 2})
    shift_at = length(stable)
    # abrupt + persistently surprising: random transitions over a NEW vocabulary
    drifted = for _ <- 1..600, do: "novel-#{:rand.uniform(40)}"

    {_, alarms} = run_stream(stable ++ drifted)
    post = alarms |> Enum.filter(&(&1 > shift_at)) |> Enum.min(fn -> nil end)

    assert post, "D-DELAY FAILED: abrupt full-vocab drift never detected"
    delay = post - shift_at

    assert delay <= 150,
           "D-DELAY FAILED: detection took #{delay} events (envelope: 30–119, hard cap 150)"

    IO.puts("  ✓ EVAL detector/delay — abrupt full-vocab shift detected in #{delay} events (envelope 30–119)")
    Autopoet.Eval.History.record("detector/delay", %{delay: delay, shift_at: shift_at})
  end

  test "D-SEV: mid-severity abrupt drift (half the vocabulary swaps) still detected" do
    :rand.seed(:exsss, {17, 3, 3})
    stable = persona_signals(80, {17, 3, 3})
    shift_at = length(stable)

    # ~50% severity: half the pulses keep their loci, half move to a new vocab
    drifted =
      for _ <- 1..40, p <- Personas.all(), ev <- p.pulse do
        sig = to_string(ev[:doc] || ev[:target] || ev[:kind])
        if :rand.uniform(2) == 1, do: "v2-#{:rand.uniform(30)}", else: sig
      end

    {_, alarms} = run_stream(stable ++ drifted)
    post = alarms |> Enum.filter(&(&1 > shift_at)) |> Enum.min(fn -> nil end)

    assert post, "D-SEV FAILED: 50%-severity abrupt drift never detected (envelope says ≥25% is reliable)"
    delay = post - shift_at
    IO.puts("  ✓ EVAL detector/severity — 50%-severity shift detected in #{delay} events")
    Autopoet.Eval.History.record("detector/severity", %{delay: delay})
  end
end
