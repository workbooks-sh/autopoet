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

  @doc """
  Run the tournament. A variant is `%{name, cfg}` (plain Hebb.Model) or
  `%{name, cfg, entrant: module}` — any module with `new/1`, `observe/2`,
  `predict_next/2` competes on identical terms (how alternative ARCHITECTURES
  earn their way in: one more row, never a rewrite).
  """
  def run(variants, seeds, k \\ 3) do
    board =
      for v <- variants do
        per_seed =
          for {seed_name, signals} <- seeds, into: %{} do
            {seed_name, score(signals, entrant(v), k)}
          end

        mean = Enum.sum(Map.values(per_seed)) / max(map_size(per_seed), 1)
        %{name: v.name, cfg: v.cfg, mean: mean, per_seed: per_seed}
      end
      |> Enum.sort_by(&(-&1.mean))

    %{leaderboard: board, winner: hd(board), k: k}
  end

  @doc "Prequential top-k hit-rate for ONE entrant over one signal stream."
  def score([first | rest], {new_fun, obs_fun, pred_fun}, k) when length(rest) >= 2 do
    {hits, n, _m} =
      Enum.reduce(rest, {0, 0, obs_fun.(new_fun.(), first)}, fn next, {hits, n, m} ->
        hit = if next in pred_fun.(m, k), do: 1, else: 0
        {hits + hit, n + 1, obs_fun.(m, next)}
      end)

    hits / n
  end

  defp entrant(%{entrant: mod, cfg: cfg}),
    do: {fn -> mod.new(cfg) end, &mod.observe/2, &mod.predict_next/2}

  defp entrant(%{cfg: cfg}),
    do: {fn -> Model.new(cfg) end, &Model.observe/2, fn m, k -> Model.predict(m, m.prev, k) end}
end
