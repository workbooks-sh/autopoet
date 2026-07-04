defmodule Autopoet.SelectEvalTest do
  @moduledoc """
  wb-phbt5 — the SELECT phase + the drain, closing Lane E:

    SELECT  a variant grid (η × decay, pinned config included) competes on the
            SAME persona seeds, prequentially, in replay. Deterministic
            leaderboard; the winner (and where pinned ranks) is the recorded
            fact. Promotion of a winner stays a human act.
    DRAIN   eval-surfaced failures filed via the real `request self` channel
            become bd issues; the brain's own queue passes through untouched.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.{Drain, Personas, Select}

  defp structured_signals(rounds, noise_pct, salt) do
    :rand.seed(:exsss, salt)

    for _ <- 1..rounds, p <- Personas.all(), ev <- p.pulse do
      if :rand.uniform(100) <= noise_pct,
        do: "noise-#{:rand.uniform(30)}",
        else: to_string(ev[:doc] || ev[:target] || ev[:kind])
    end
  end

  defp drift_signals(rounds) do
    a = structured_signals(rounds, 5, {19, 19, 19})
    b = for s <- structured_signals(rounds, 5, {23, 23, 23}), do: "v2/#{s}"
    a ++ b
  end

  test "SELECT: the variant tournament is deterministic and ranks the grid on persona seeds" do
    pinned = Autopoet.Shadow.Hebb.Model.default_cfg()

    variants =
      for eta <- [0.2, pinned.eta, 0.5],
          decay <- [0.995, pinned.decay, 0.9999] do
        name = if eta == pinned.eta and decay == pinned.decay, do: "PINNED", else: "eta#{eta}-d#{decay}"
        %{name: name, cfg: %{eta: eta, decay: decay}}
      end

    seeds = [
      {"structured", structured_signals(30, 10, {29, 29, 29})},
      {"drift", drift_signals(15)}
    ]

    result = Select.run(variants, seeds)

    # deterministic: same tournament, same leaderboard
    assert result == Select.run(variants, seeds)

    board = result.leaderboard
    assert length(board) == 9
    assert board == Enum.sort_by(board, &(-&1.mean))
    assert Enum.all?(board, &(&1.mean > 0.0 and &1.mean <= 1.0))

    pinned_rank = Enum.find_index(board, &(&1.name == "PINNED")) + 1
    winner = result.winner

    Autopoet.Eval.History.record("select", %{
      winner: winner.name,
      winner_mean: winner.mean,
      pinned_rank: pinned_rank,
      pinned_mean: Enum.find(board, &(&1.name == "PINNED")).mean,
      variants: length(board)
    })

    IO.puts(
      "  ✓ EVAL select — winner #{winner.name} (mean #{fmt(winner.mean)}) · " <>
        "PINNED ranks #{pinned_rank}/9 (#{fmt(Enum.find(board, &(&1.name == "PINNED")).mean)}) · " <>
        "spread #{fmt(List.last(board).mean)}–#{fmt(hd(board).mean)}"
    )

    if pinned_rank > 3 do
      IO.puts("  ! EVAL select — PINNED is dominated; consider a pre-registered constant change (human act)")
    end
  end

  test "DRAIN: eval failures become bd issues; the brain's queue passes through" do
    uniq = "drain#{System.unique_integer([:positive])}"

    # a brain-owned request that must SURVIVE the drain…
    :ok = Autopoet.Requests.file("#{uniq}-brainwork", "the brain's own errand")
    # …and an eval failure filed through the same channel
    :ok = Drain.file_failure("#{uniq}-gate", "G-STRUCT regressed on trace X (hebb 0.31 vs freq 0.29)")
    Process.sleep(400)

    calls = :ets.new(:drain_calls, [:public])

    {filed, kept} =
      Drain.drain(fn cmd, args ->
        :ets.insert(calls, {cmd, args})
        {:ok, "wb-fake"}
      end)

    assert filed >= 1
    assert kept >= 1

    assert [{"bd", args}] =
             :ets.tab2list(calls)
             |> Enum.filter(fn {_, a} -> Enum.any?(a, &String.contains?(&1, uniq)) end)

    assert "create" in args
    assert Enum.any?(args, &String.contains?(&1, "[eval] #{uniq}-gate"))
    assert Enum.any?(args, &String.contains?(&1, "G-STRUCT regressed"))

    # the brain's errand was re-filed, not eaten
    Process.sleep(400)
    pending = Autopoet.Requests.pending()
    assert Enum.any?(pending, &(to_string(&1[:target]) == "#{uniq}-brainwork"))
    refute Enum.any?(pending, &(to_string(&1[:target]) == "eval:#{uniq}-gate"))

    IO.puts("  ✓ EVAL drain — #{filed} eval failure(s) → bd, #{kept} brain request(s) passed through")
  end

  defp fmt(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
end
