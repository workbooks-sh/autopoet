defmodule Autopoet.Shadow.Profile do
  @moduledoc """
  The BEAM-native "companion" analysis layer over the captured event corpus —
  Scholar (elixir-nx), NO Python sidecar. It turns the per-locus feature table
  (from `Autopoet.Shadow.Trace`) into a LEARNED behavioral clustering: instead of
  hand-picked entropy thresholds ("H < 0.15 = spine"), a GaussianMixture discovers
  the behavioral types from the data — deterministic spine vs decision/branch — so
  the boundary is learned and scales as the corpus grows.

  Lives in `desktop_ml/` (compiled desktop/dev only, where Scholar+Nx are present;
  the cloud brain never runs offline profiling). Read `Trace`, build features,
  cluster, interpret. Companion to the sequence layer (minGRU/entropy-monitor),
  not a replacement — this reasons over DERIVED tabular features, not raw order.

  Point it at the captured corpus and it returns the learned behavioural bands;
  the clustering sharpens as the corpus grows. A learned band supersedes the
  hand-tuned entropy thresholds once it holds up on a larger run set.
  """

  # Per-locus feature columns (interpretable, few — right-sized for small N):
  #   log10(count+1)  ·  H(next) bits  ·  distinct-next fraction of vocab
  @doc """
  Feature table for the loci in `signals`: `{loci, tensor}` where `tensor` is
  `[n_loci, 3]` = `[log_count, entropy_bits, distinct_frac]`. Loci seen fewer than
  `:min_count` times are dropped (too sparse to characterize).
  """
  def features(signals, opts \\ []) do
    min_count = Keyword.get(opts, :min_count, 3)
    vocab = signals |> MapSet.new() |> MapSet.size() |> max(1)

    trans =
      signals
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(%{}, fn [a, b], m ->
        Map.update(m, a, %{b => 1}, fn d -> Map.update(d, b, 1, &(&1 + 1)) end)
      end)

    rows =
      trans
      |> Enum.filter(fn {_l, dist} -> dist |> Map.values() |> Enum.sum() >= min_count end)
      |> Enum.map(fn {locus, dist} ->
        total = dist |> Map.values() |> Enum.sum()
        {locus, [:math.log10(total + 1), entropy(dist), map_size(dist) / vocab], entropy(dist)}
      end)
      |> Enum.sort_by(fn {_, _, h} -> h end)

    loci = Enum.map(rows, fn {l, _, _} -> l end)
    feats = Enum.map(rows, fn {_, f, _} -> f end)
    tensor = if feats == [], do: Nx.tensor([[0.0, 0.0, 0.0]]), else: Nx.tensor(feats)
    {loci, tensor}
  end

  defp entropy(dist) do
    total = dist |> Map.values() |> Enum.sum()

    dist
    |> Map.values()
    |> Enum.reduce(0.0, fn c, h ->
      p = c / total
      h - p * :math.log2(p)
    end)
  end

  @doc """
  Cluster the loci into `k` behavioral types with Scholar's GaussianMixture over
  standardized features, then LABEL clusters by ascending mean entropy
  (deterministic-spine → mostly-fixed → branch/decision). Returns
  `%{loci: [%{locus, type, count-ish, entropy, distinct_frac}], types: %{id => label}}`.

  Falls back to `:insufficient_loci` when there are fewer distinct loci than `k`
  (GaussianMixture needs num_gaussians <= num_samples).
  """
  def cluster(signals, opts \\ []) do
    k = Keyword.get(opts, :k, 3)
    {loci, x} = features(signals, opts)
    n = length(loci)

    if n < k do
      :insufficient_loci
    else
      xs = Scholar.Preprocessing.StandardScaler.fit_transform(x)
      key = Nx.Random.key(Keyword.get(opts, :seed, 17))
      model = Scholar.Cluster.GaussianMixture.fit(xs, num_gaussians: k, key: key)
      assign = model |> Scholar.Cluster.GaussianMixture.predict(xs) |> Nx.to_flat_list()

      entropies = x[[.., 1]] |> Nx.to_flat_list()

      # mean entropy per raw cluster id → rank → human label
      mean_h =
        Enum.zip(assign, entropies)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {cid, hs} -> {cid, Enum.sum(hs) / length(hs)} end)

      ranked = mean_h |> Enum.sort_by(fn {_cid, h} -> h end) |> Enum.map(&elem(&1, 0))
      labels = label_by_rank(ranked)
      types = Map.new(ranked, fn cid -> {cid, labels[cid]} end)

      rows =
        [loci, assign, Nx.to_flat_list(x[[.., 0]]), entropies, Nx.to_flat_list(x[[.., 2]])]
        |> Enum.zip()
        |> Enum.map(fn {locus, cid, logc, h, df} ->
          %{locus: locus, type: types[cid], log_count: logc, entropy: h, distinct_frac: df}
        end)

      %{loci: rows, types: types}
    end
  end

  # Map entropy-ranked cluster ids to labels. Any k: lowest = spine, highest =
  # branch, middles = graded.
  defp label_by_rank(ranked) do
    last = length(ranked) - 1

    ranked
    |> Enum.with_index()
    |> Map.new(fn {cid, i} ->
      label =
        cond do
          i == 0 -> "deterministic-spine"
          i == last -> "branch/decision"
          true -> "mostly-fixed"
        end

      {cid, label}
    end)
  end
end
