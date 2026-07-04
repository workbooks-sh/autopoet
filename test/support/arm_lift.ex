defmodule Autopoet.Eval.ArmLift do
  @moduledoc """
  wb-8lxzv — the recall-A/B arm-lift scorer: does WARM context ordering lift
  proposal acceptance over FLAT? Intent-to-treat over the captured trace:

    1. every `recall.ab` event assigns its target an arm (the actuator emits
       one per context assembly — the durable record of the experiment),
    2. a `proposal.recorded` for that target inherits the target's CURRENT arm
       (the proposal was drafted under that ordering), keyed by proposal id,
    3. `proposal.accepted` / `proposal.rejected` resolve the id → the verdict
       tallies under the arm that produced it.

  Returns per-arm `%{assigned, proposals, accepted, rejected, rate}` plus
  `lift` (warm rate − flat rate) and `decided` (total resolved verdicts).
  Rates are acceptance over RESOLVED proposals only; pending ones don't count
  either way. Pure over frames — recomputable from any trace.
  """

  def score(frames) do
    init = %{
      arm_by_target: %{},
      arm_by_proposal: %{},
      tally: %{
        "warm" => %{assigned: 0, proposals: 0, accepted: 0, rejected: 0},
        "flat" => %{assigned: 0, proposals: 0, accepted: 0, rejected: 0}
      }
    }

    final = Enum.reduce(frames, init, &step(&2, &1))

    tally =
      Map.new(final.tally, fn {arm, t} ->
        decided = t.accepted + t.rejected
        {arm, Map.put(t, :rate, if(decided == 0, do: nil, else: t.accepted / decided))}
      end)

    warm = tally["warm"]
    flat = tally["flat"]

    %{
      warm: warm,
      flat: flat,
      decided: warm.accepted + warm.rejected + flat.accepted + flat.rejected,
      lift: if(warm.rate && flat.rate, do: warm.rate - flat.rate, else: nil)
    }
  end

  defp step(acc, %{kind: "recall.ab"} = ev) do
    arm = to_string(ev[:arm])

    acc
    |> put_in([:arm_by_target, to_string(ev[:target])], arm)
    |> update_in([:tally, arm, :assigned], &(&1 + 1))
  end

  defp step(acc, %{kind: "proposal.recorded"} = ev) do
    case Map.get(acc.arm_by_target, to_string(ev[:target])) do
      nil ->
        acc

      arm ->
        acc
        |> put_in([:arm_by_proposal, to_string(ev[:proposal])], arm)
        |> update_in([:tally, arm, :proposals], &(&1 + 1))
    end
  end

  defp step(acc, %{kind: kind} = ev) when kind in ~w(proposal.accepted proposal.rejected) do
    case Map.get(acc.arm_by_proposal, to_string(ev[:proposal])) do
      nil ->
        acc

      arm ->
        field = if kind == "proposal.accepted", do: :accepted, else: :rejected
        update_in(acc, [:tally, arm, field], &(&1 + 1))
    end
  end

  defp step(acc, _ev), do: acc
end
