defmodule Autopoet.Eval.Integrity do
  @moduledoc """
  Eval D4 (wb-q351b.4) — feedback-integrity sweeps: pure functions over a
  captured `.etfs` trace that check the phase-0 exit criteria on ANY trace,
  production or synthetic. No mocks; the trace is the ground truth.

    * settle sweep — every `effect.settled` is well-formed (hook/effect/status/
      duration_us/cause) and its `cause` resolves to an event seen in the trace.
    * chain sweep — every event carrying `cause:` names an id seen EARLIER in
      the trace (causation chains reconstruct to their roots, in order).
    * conservation — folding the trace through the REAL ledger arithmetic
      (`Outcomes.Model`, shared verbatim with the live GenServer) is
      deterministic: same trace, same ledger, every time.
  """

  alias Autopoet.Shadow.Outcomes.Model

  @doc """
  Sweep `effect.settled` events. Returns
  `%{settled, well_formed, cause_resolved, violations: [event]}` —
  a violation is malformed or has a cause id absent from the trace.
  """
  def settle_sweep(frames) do
    ids = MapSet.new(frames, & &1[:id])
    settled = Enum.filter(frames, &(&1[:kind] == "effect.settled"))

    {ok, bad} =
      Enum.split_with(settled, fn ev ->
        well_formed?(ev) and MapSet.member?(ids, ev[:cause])
      end)

    %{
      settled: length(settled),
      well_formed: Enum.count(settled, &well_formed?/1),
      cause_resolved: length(ok),
      violations: bad
    }
  end

  @doc """
  Sweep causation chains. Returns `%{caused, resolved, forward_refs, orphans}` —
  an orphan's cause id appears nowhere in the trace; a forward_ref names an id
  only seen LATER (ordering break: capture is append-in-delivery-order).
  """
  def chain_sweep(frames) do
    ids = MapSet.new(frames, & &1[:id])

    {stats, _seen} =
      Enum.reduce(frames, {%{caused: 0, resolved: 0, forward_refs: 0, orphans: 0}, MapSet.new()}, fn
        ev, {st, seen} ->
          st =
            case ev[:cause] do
              nil ->
                st

              cause ->
                st = %{st | caused: st.caused + 1}

                cond do
                  MapSet.member?(seen, cause) -> %{st | resolved: st.resolved + 1}
                  MapSet.member?(ids, cause) -> %{st | forward_refs: st.forward_refs + 1}
                  true -> %{st | orphans: st.orphans + 1}
                end
            end

          {st, MapSet.put(seen, ev[:id])}
      end)

    stats
  end

  @doc "Fold a trace through the real ledger arithmetic. Deterministic by construction — the conservation check."
  def replay_ledger(frames), do: Enum.reduce(frames, Model.new(), &Model.reduce(&2, &1))

  defp well_formed?(ev) do
    is_binary(ev[:hook] || nil) and is_binary(ev[:effect] || nil) and
      ev[:status] in [:ok, :error] and is_integer(ev[:duration_us]) and not is_nil(ev[:cause])
  end
end
