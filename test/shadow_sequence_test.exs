defmodule Autopoet.Shadow.SequenceTest do
  use ExUnit.Case, async: false

  # Nx makes training nondeterministic across backends; run serially, keep the stream
  # small so the in-BEAM minGRU trains fast enough for the suite.
  alias Autopoet.Shadow.Sequence

  test "insufficient data is handled, not crashed" do
    assert %{verdict: :insufficient_data, bits: nil} = Sequence.analyze(["a", "b", "a", "b"])
  end

  test "analyze trains a minGRU and returns a learned-vs-Markov scorecard" do
    :rand.seed(:exsss, {1, 2, 3})
    chain = %{"a" => ["b", "c"], "b" => ["d"], "c" => ["d"], "d" => ["a"]}

    stream =
      Enum.reduce(1..1500, ["a"], fn _i, acc ->
        [Enum.random(Map.fetch!(chain, hd(acc))) | acc]
      end)
      |> Enum.reverse()

    r = Sequence.analyze(stream, max_steps: 400)
    assert r.vocab == 4
    assert r.trained_steps > 0
    assert is_float(r.bits) and is_float(r.markov_bits)
    # learned must BEAT simple to win — on a first-order chain the honest verdict is
    # that the baseline suffices (or ties); either is a valid, non-crashing outcome.
    assert r.verdict in [:baseline_sufficient, :learned_beats_markov]
  end
end
