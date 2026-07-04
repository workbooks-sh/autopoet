defmodule Autopoet.Eval.Select do
  @moduledoc """
  wb-phbt5 — the SELECT phase: variant configurations compete on the SAME
  persona seeds, prequentially, in replay. The darwin-gödel vignette made
  measurable and boring: no mutation of the live system, just a tournament
  whose leaderboard accumulates in eval/history.log; promoting a winner to the
  pinned config stays a HUMAN act (pre-registration discipline).

  `run(variants, seeds, k)` — variants `%{name, cfg}` (Hebb.Model cfg),
  seeds `{seed_name, [signal]}`. Every variant is scored on every seed
  (predict-then-observe top-k hit-rate); rank by mean score. Deterministic:
  same inputs, same leaderboard.
  """

  alias Autopoet.Shadow.Hebb.Model

  def run(variants, seeds, k \\ 3) do
    board =
      for %{name: name, cfg: cfg} <- variants do
        per_seed =
          for {seed_name, signals} <- seeds, into: %{} do
            {seed_name, score(signals, cfg, k)}
          end

        mean = Enum.sum(Map.values(per_seed)) / max(map_size(per_seed), 1)
        %{name: name, cfg: cfg, mean: mean, per_seed: per_seed}
      end
      |> Enum.sort_by(&(-&1.mean))

    %{leaderboard: board, winner: hd(board), k: k}
  end

  @doc "Prequential top-k hit-rate for ONE cfg over one signal stream (the real Model arithmetic)."
  def score([first | rest], cfg, k) when length(rest) >= 2 do
    {hits, n, _m} =
      Enum.reduce(rest, {0, 0, Model.observe(Model.new(cfg), first)}, fn next, {hits, n, m} ->
        hit = if next in Model.predict(m, m.prev, k), do: 1, else: 0
        {hits + hit, n + 1, Model.observe(m, next)}
      end)

    hits / n
  end
end
