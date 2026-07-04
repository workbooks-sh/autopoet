defmodule Autopoet.HeartbeatEvalTest do
  @moduledoc """
  Eval D1 (wb-q351b.2) — heartbeat-cycle liveness: the WHOLE beat through the
  production shape, no network. The armed heartbeat is `Scheduler → event →
  hook → autopoet.cycle effect → Brain.cycle → Worker.run_once`; this eval
  fires that exact chain from the bus side and asserts every stage moved:

    SENSE    a filed request + a telemetry concern are both picked up
    PROPOSE  the injected brain answers; the body is written (direct lane)
    GATE     a vault-target item escalates (human-gated), never merges
    LEARN    knowledge.work grows a lesson for each routed item
    SETTLE   the cycle effect settles onto the bus with cause + duration
    LEDGER   the settle lands in the outcome ledger under the cycle hook
    LATENCY  request→resolution wall-clock reported (scorecard number)
  """
  use ExUnit.Case, async: false

  test "one full beat: sense → propose → gate → learn → settle → ledger" do
    uniq = "beat#{System.unique_integer([:positive])}"
    fname = "#{uniq}.work"
    body_file = Path.join(Autopoet.Body.root(), fname)
    on_exit(fn -> File.rm(body_file) end)

    # the brain answers every item with a complete page for our unique file
    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "=== file: #{fname} ===\n# #{uniq}\n\nWritten by one heartbeat.\n"}
    end)

    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    # SENSE inputs, both kinds: a real filed request…
    :ok = Autopoet.Requests.file(uniq, "write the #{uniq} page")

    # …and a real telemetry concern (a unit that keeps failing)
    for _ <- 1..4 do
      Nexus.Telemetry.record(uniq, %{at: 0, turns: 1, tokens: %{total: 1}, latency_ms: 1, tools: %{}, status: :error, error: "boom"})
    end

    # the production trigger shape: bus event → hook → autopoet.cycle effect
    beat_hook = "#{uniq}_beat"

    Nexus.Hook.register(%{
      name: beat_hook,
      match: %{tags: [uniq]},
      trigger: nil,
      title: uniq,
      visible_to: nil,
      effects: [%{name: "autopoet.cycle", args: %{}}]
    })

    Nexus.Events.subscribe()
    lessons0 = Nexus.Autopoet.Knowledge.count()
    t0 = System.monotonic_time(:millisecond)

    Nexus.Events.emit(%{kind: "#{uniq}.tick", tags: [uniq]})

    # SETTLE: the cycle effect settles back onto the bus
    assert_receive {:event, %{kind: "effect.settled", hook: ^beat_hook} = settled}, 15_000
    latency_ms = System.monotonic_time(:millisecond) - t0
    assert settled[:effect] == "autopoet.cycle"
    assert settled[:status] == :ok

    # PROPOSE/ACT: the brain wrote the body through the direct lane
    assert File.exists?(body_file), "the beat did not write #{fname}"
    assert File.read!(body_file) =~ "Written by one heartbeat"

    # SENSE proof: the request AND the concern were both routed in the report
    report = Nexus.Autopoet.Worker.status().last
    assert report.sensed >= 2, "expected request + concern sensed, got #{report.sensed}"
    targets = Enum.map(report.results, & &1.target)
    assert uniq in targets

    # LEARN: knowledge.work grew a lesson per routed item
    lessons = Nexus.Autopoet.Knowledge.count()
    assert lessons > lessons0, "no lesson appended (#{lessons0} → #{lessons})"

    # LEDGER: the settle landed in the outcome ledger under the cycle hook
    Process.sleep(300)
    assert %{ok: n} = Autopoet.Shadow.Outcomes.ledger().effects[{beat_hook, "autopoet.cycle"}]
    assert n >= 1

    IO.puts(
      "  ✓ EVAL heartbeat — beat settled in #{latency_ms}ms · sensed #{report.sensed} · " <>
        "actions #{inspect(Enum.map(report.results, & &1.action))} · lessons +#{lessons - lessons0}"
    )

    Autopoet.Eval.History.record("heartbeat", %{latency_ms: latency_ms, sensed: report.sensed, lessons: lessons - lessons0})
  end

  test "gate: a grant-widening change escalates to the human, never merges (the triad holds)" do
    uniq = "gated#{System.unique_integer([:positive])}"
    rel = "crew/#{uniq}.work"
    body_file = Path.join(Autopoet.Body.root(), rel)
    File.mkdir_p!(Path.dirname(body_file))

    # an existing agent with a narrow grant…
    File.write!(body_file, "# crew\n\nagent :#{uniq} do\n  prompt \"watch\"\n  grant net\nend\n")
    on_exit(fn -> File.rm(body_file) end)

    # …that the brain tries to hand MORE POWER (grant net → net, secrets)
    Application.put_env(:autopoet, :brain_llm, fn _prompt ->
      {:ok, "=== file: #{rel} ===\n# crew\n\nagent :#{uniq} do\n  prompt \"watch\"\n  grant net, secrets\nend\n"}
    end)

    on_exit(fn -> Application.delete_env(:autopoet, :brain_llm) end)

    escalations = :ets.new(:esc, [:public])

    report =
      Nexus.Autopoet.Worker.run_once(
        root: Autopoet.Body.root(),
        requests: [%{target: uniq, change: "widen the grant"}],
        proposer: &Autopoet.Brain.propose/1,
        notify: fn item, reasons -> :ets.insert(escalations, {item[:target], reasons}) end
      )

    ours = Enum.filter(report.results, &(&1.target == uniq))
    assert Enum.map(ours, & &1.action) == [:escalated],
           "grant widening must escalate, got #{inspect(ours)}"

    assert [{_, reasons}] = :ets.lookup(escalations, uniq)
    assert Enum.any?(reasons, &match?({:grant, _}, &1)), "escalation must name the grant: #{inspect(reasons)}"

    # nothing landed on disk — the narrow grant is still what registers
    assert File.read!(body_file) =~ "grant net\n"
    refute File.read!(body_file) =~ "secrets"

    # and the change is waiting as a PENDING proposal for the human verb
    assert Enum.any?(Autopoet.Proposals.pending(), fn {id, _} ->
             Autopoet.Proposals.target_of(id) == uniq
           end)

    IO.puts("  ✓ EVAL heartbeat/gate — grant widening escalated with #{inspect(reasons)}; body untouched, proposal pending (triad holds)")
  end
end
