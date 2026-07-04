defmodule Autopoet.EfficiencyEvalTest do
  @moduledoc """
  Eval D3 (wb-q351b.3) — efficiency: learning must stay microsecond-cheap and
  memory-plateaued, or the thesis ("plasticity is table updates, none of it
  wants a GPU") is broken in practice.

  GATES:
    E-CPU     the pure model observes at < 50µs/event (50k-event budget check).
    E-BUS     learners keep up with a live burst — queues drain to zero, and the
              whole burst lands in every learner.
    E-MEM     memory is vocabulary-bound, not event-bound: a second identical
              burst may not meaningfully grow the learner processes.
    E-MONEY   the admission boundary is readable and never raises (the cost
              scaffold the phase-2 amortization KPI will draw from).
  """
  use ExUnit.Case, async: false

  alias Autopoet.Shadow.Hebb.Model

  test "E-CPU: pure Hebbian observe stays under 50µs/event over 50k events" do
    :rand.seed(:exsss, {3, 3, 3})
    vocab = for i <- 1..40, do: "eff-#{i}"
    signals = for _ <- 1..50_000, do: Enum.random(vocab)

    {us, final} =
      :timer.tc(fn ->
        Enum.reduce(signals, Model.new(), &Model.observe(&2, &1))
      end)

    per_event = us / 50_000
    assert final.n == 50_000
    assert per_event < 50, "E-CPU FAILED: #{Float.round(per_event, 2)}µs/event (budget 50µs)"

    IO.puts("  ✓ EVAL efficiency/cpu — #{Float.round(per_event, 2)}µs/event over 50k (#{div(us, 1000)}ms total)")
    Autopoet.Eval.History.record("efficiency/cpu", %{us_per_event: per_event})
  end

  test "E-BUS + E-MEM: live burst — queues drain, memory plateaus on a fixed vocabulary" do
    learners = [Autopoet.Shadow.Hebb, Autopoet.Shadow.Surprise, Autopoet.Shadow.Outcomes]
    uniq = "ebus#{System.unique_integer([:positive])}"
    burst = fn -> for i <- 1..1_500, do: Nexus.Events.emit(%{kind: "#{uniq}.pulse", doc: "#{uniq}-#{rem(i, 25)}", tags: []}) end

    n0 = Autopoet.Shadow.Hebb.stats().events
    {us, _} = :timer.tc(burst)
    assert drained?(learners, n0 + 1_500), "E-BUS FAILED: learners lagged the burst"
    mem1 = total_memory(learners)

    n1 = Autopoet.Shadow.Hebb.stats().events
    burst.()
    assert drained?(learners, n1 + 1_500)
    mem2 = total_memory(learners)

    events_per_sec = round(1_500 / (us / 1_000_000))

    # STATE footprint (heap words), not process_info(:memory) — the latter is GC
    # jitter and flaked under mix eval ordering (same fix as the soak eval)
    assert mem2 <= mem1 * 1.25,
           "E-MEM FAILED: identical vocab burst grew learner state #{mem1} → #{mem2} words"

    IO.puts(
      "  ✓ EVAL efficiency/bus+mem — burst emitted at #{events_per_sec} ev/s · queues drained · " <>
        "learner state #{div(mem1 * 8, 1024)}KB → #{div(mem2 * 8, 1024)}KB on repeat vocab"
    )

    Autopoet.Eval.History.record("efficiency/bus", %{events_per_sec: events_per_sec, state_kb: div(mem2 * 8, 1024)})
  end

  test "E-MONEY: the admission boundary is readable and never raises" do
    status = Nexus.Inference.Admission.status(Nexus.Store.default_tenant())
    assert is_map(status)
    assert Map.has_key?(status, :balance)

    IO.puts("  ✓ EVAL efficiency/money — admission readable: #{inspect(Map.take(status, [:balance, :enforce]))}")
  end

  # learners processed the burst AND their mailboxes are empty
  defp drained?(learners, target_events, tries \\ 100) do
    cond do
      tries == 0 ->
        false

      Autopoet.Shadow.Hebb.stats().events >= target_events and
          Enum.all?(learners, fn mod ->
            {:message_queue_len, q} = Process.info(Process.whereis(mod), :message_queue_len)
            q == 0
          end) ->
        true

      true ->
        Process.sleep(50)
        drained?(learners, target_events, tries - 1)
    end
  end

  # learner STATE footprint in heap words — precise + GC-independent
  defp total_memory(learners) do
    Enum.sum(for mod <- learners, do: :erts_debug.flat_size(:sys.get_state(Process.whereis(mod))))
  end
end
