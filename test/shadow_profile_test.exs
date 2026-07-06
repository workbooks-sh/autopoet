defmodule Autopoet.ShadowProfileTest do
  # async: false — GMM/Nx training shares backend state; interleaving with other
  # Nx work makes the clustering nondeterministic. Run this suite serially.
  use ExUnit.Case, async: false

  alias Autopoet.Shadow.Profile

  @moduledoc false
  # Locks the BEAM-native companion (Scholar): the feature table must be shaped
  # right, and GaussianMixture must separate a deterministic-spine locus from a
  # high-entropy branch locus into different learned types.

  test "features are [n_loci, 3] and drop sparse loci" do
    # 'a'->'b' always (spine, deterministic); 'c' branches; 'z' seen once (sparse)
    signals = List.duplicate(["a", "b"], 20) |> List.flatten()
    signals = signals ++ Enum.flat_map(1..20, fn _ -> ["c", Enum.random(~w(d e f))] end) ++ ["z"]

    {loci, x} = Profile.features(signals, min_count: 3)
    assert "a" in loci and "c" in loci
    refute "z" in loci, "singleton locus must be dropped as too sparse"
    assert Nx.axis_size(x, 1) == 3
    assert Nx.axis_size(x, 0) == length(loci)
  end

  test "GMM separates a deterministic spine from a branch point into distinct types" do
    # Build a stream with three clear regimes:
    #   spine1: p -> q always (H=0)
    #   spine2: m -> n always (H=0)
    #   branch: b -> {t,u,v,w} uniformly (H=2)
    spine = List.duplicate(["p", "q"], 60) |> List.flatten()
    spine2 = List.duplicate(["m", "n"], 60) |> List.flatten()
    :rand.seed(:exsss, {5, 5, 5})
    branch = Enum.flat_map(1..120, fn _ -> ["b", Enum.random(~w(t u v w))] end)
    signals = spine ++ spine2 ++ branch

    assert %{loci: rows} = Profile.cluster(signals, k: 3, seed: 3)

    type_of = fn locus -> Enum.find(rows, &(&1.locus == locus)).type end
    # The meaningful invariant: the high-entropy branch source is isolated as a
    # decision point, and the deterministic spine source is NOT — they land in
    # different learned types. (GMM may sub-split the low-entropy mass by count/
    # branching, so 'p' may be "deterministic-spine" or "mostly-fixed" — both are
    # correctly NOT "branch/decision".)
    assert type_of.("b") == "branch/decision"
    refute type_of.("p") == "branch/decision"
    assert type_of.("p") != type_of.("b")
  end

  test "insufficient loci is handled, not crashed" do
    assert :insufficient_loci == Profile.cluster(["a", "b", "a", "b"], k: 3)
  end
end
