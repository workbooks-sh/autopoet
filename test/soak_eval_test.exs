defmodule Autopoet.SoakEvalTest do
  @moduledoc """
  Eval D7 (wb-q351b.7) — the soak: a wall-clock-bounded synthetic life on the
  real bus. Three regimes: steady persona traffic → an abrupt regime shift →
  a NEW steady rhythm. The living system must:

    S-LEARN   keep learning the whole time (event counts strictly grow)
    S-ALARM   notice the shift (≥1 drift alarm around the transition)
    S-QUENCH  calm back down once the new rhythm is learnable (no new alarms
              in the final quarter)
    S-MEM     hold a memory plateau (end ≤ 1.5× mid, fixed vocabularies)
    S-DRAIN   end with empty learner queues
    S-SNAP    snapshot every learner to disk at the end

  Duration: AUTOPOET_SOAK_SECONDS (default 15 — CI-sized; set 3600+ for the
  real overnight soak). Wall-clock bounded, never turn-capped.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Eval.Personas

  @tag timeout: :infinity
  test "soak: steady → shift → new steady; learn, alarm, quench, plateau" do
    total_s =
      case System.get_env("AUTOPOET_SOAK_SECONDS") do
        nil -> 15
        s -> String.to_integer(s)
      end

    uniq = "soak#{System.unique_integer([:positive])}"
    learners = [Autopoet.Shadow.Hebb, Autopoet.Shadow.Surprise, Autopoet.Shadow.Outcomes]

    # structured rhythms: personas' pulses (regime A) vs a renamed world (regime C)
    rhythm_a =
      for p <- Personas.all(), ev <- p.pulse, do: Map.put(ev, :tags, [])

    rhythm_c =
      for p <- Personas.all(), ev <- p.pulse do
        %{kind: "doc.touch", doc: "#{uniq}/#{ev[:doc] || ev[:target] || ev[:kind]}", tags: []}
      end

    :rand.seed(:exsss, {17, 17, 17})
    shift_burst = for _ <- 1..600, do: %{kind: "doc.touch", doc: "#{uniq}-chaos-#{:rand.uniform(50)}", tags: []}

    n0 = Autopoet.Shadow.Hebb.stats().events
    alarms0 = Autopoet.Shadow.Surprise.stats().alarms

    # ── regime A: steady persona life (40% of budget) ────────────────────────
    drive(rhythm_a, total_s * 400)
    mid_events = Autopoet.Shadow.Hebb.stats().events
    assert mid_events > n0, "S-LEARN FAILED: nothing learned in regime A"

    # ── the shift: abrupt, severe, novel (fires the detector) ────────────────
    Enum.each(shift_burst, &Nexus.Events.emit/1)

    # ── regime C: a new steady rhythm (40% of budget) ────────────────────────
    drive(rhythm_c, total_s * 200)
    alarms_shift = Autopoet.Shadow.Surprise.stats().alarms
    assert alarms_shift > alarms0, "S-ALARM FAILED: the regime shift raised no drift alarm"

    settle_mem = learner_memory(learners)

    drive(rhythm_c, total_s * 200)
    alarms_end = Autopoet.Shadow.Surprise.stats().alarms
    end_events = Autopoet.Shadow.Hebb.stats().events
    end_mem = learner_memory(learners)

    # S-QUENCH: the new rhythm became ordinary — no fresh alarms in the last leg
    assert alarms_end == alarms_shift,
           "S-QUENCH FAILED: #{alarms_end - alarms_shift} alarm(s) after the new rhythm settled"

    assert end_events > mid_events, "S-LEARN FAILED: learning stopped after the shift"

    # vocabulary-bound means STATE size (words), not process heap (GC jitter):
    # after regime C's vocabulary is fully seen, another leg only updates floats
    # in place — the state may not keep growing
    assert end_mem <= settle_mem * 1.25, "S-MEM FAILED: learner state #{settle_mem} → #{end_mem} words on a fixed vocabulary"
    assert drained?(learners), "S-DRAIN FAILED: learner queues not empty at soak end"

    for mod <- learners, do: assert(:ok = mod.snapshot())
    for name <- ~w(hebb surprise outcomes) do
      assert File.exists?(Path.join(Autopoet.Shadow.dir(), "#{name}.etf")), "S-SNAP: #{name}.etf missing"
    end

    IO.puts(
      "  ✓ EVAL soak (#{total_s}s) — events +#{end_events - n0} · alarms +#{alarms_shift - alarms0} at shift, " <>
        "0 after quench · learner state #{div(settle_mem * 8, 1024)}KB → #{div(end_mem * 8, 1024)}KB · queues drained · snapshots on disk"
    )

    Autopoet.Eval.History.record("soak", %{
      seconds: total_s,
      events: end_events - n0,
      shift_alarms: alarms_shift - alarms0,
      quench_alarms: alarms_end - alarms_shift,
      state_kb: div(end_mem * 8, 1024)
    })
  end

  # emit the rhythm repeatedly for `budget_ms`, pacing so the bus breathes
  defp drive(rhythm, budget_ms) do
    t0 = System.monotonic_time(:millisecond)

    Stream.cycle([:beat])
    |> Enum.reduce_while(:ok, fn _, _ ->
      Enum.each(rhythm, &Nexus.Events.emit/1)
      Process.sleep(20)

      if System.monotonic_time(:millisecond) - t0 >= budget_ms,
        do: {:halt, :ok},
        else: {:cont, :ok}
    end)
  end

  defp drained?(learners, tries \\ 100) do
    cond do
      tries == 0 ->
        false

      Enum.all?(learners, fn mod ->
        {:message_queue_len, q} = Process.info(Process.whereis(mod), :message_queue_len)
        q == 0
      end) ->
        true

      true ->
        Process.sleep(50)
        drained?(learners, tries - 1)
    end
  end

  # the learners' actual STATE footprint in heap words — precise and
  # GC-independent, unlike process_info(:memory)
  defp learner_memory(learners) do
    Enum.sum(
      for mod <- learners do
        :erts_debug.flat_size(:sys.get_state(Process.whereis(mod)))
      end
    )
  end
end
