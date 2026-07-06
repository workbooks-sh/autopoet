defmodule Autopoet.Shadow.Triage do
  @moduledoc """
  The FIRST live substrate consumer of the resident micro-brain (`Autopoet.Micro`).

  Today a `Shadow.Surprise` drift alarm is an unexplained number: "surprise fast
  1.9 vs slow 0.7 bits" fires an `autopoet.attention` event and stops there — no
  next step. This module adds net-new signal: on alarm, the 1B micro-brain picks
  the first DIAGNOSTIC ACTION for the drifting locus (recall its neighbors, pull
  its history, read its outcome ledger, or — given enough — hypothesize), and that
  suggestion rides out as an enriched `autopoet.attention.triaged` event.

  Three hard rules, all Phase-1 exit criteria:

    * **Advisory only.** A suggestion is a hint for a downstream consumer; it never
      mutates the body, merges a proposal, or changes the pinned detector's
      arithmetic. Same containment rung as `Shadow.Hebb.recall/2`.
    * **Zero heartbeat latency.** The `Micro.decide/3` call is a ~1-2s network
      round-trip; running it inline would stall the shadow bus subscriber. So
      `on_alarm/2` returns immediately and does the work in a SUPERVISED task.
      The Surprise GenServer never blocks.
    * **Degrade to exactly today.** Disabled (`Micro.enabled?/0` false) or model
      down (`Micro.available?/0` false) → no task, no event, no error. The
      substrate behaves precisely as it did before this module existed.

  ## Few-shot library (format discipline is non-negotiable)

  The 1B narrates instead of emitting a parseable `CALL` unless the prompt carries
  a rigid template + a one-shot example (proven in `nexus/spike/micro_triage_eval`).
  Each decision-SITE owns its example. There is one site today — `:drift` — and
  new sites add their own `{situation, "CALL ..."}` pair to `@sites`.
  """

  # The fixed diagnostic vocabulary a drift alarm chooses from. Mirrors the
  # shadow layer's own read surfaces (Hebb.recall, event history, Outcomes ledger).
  @tools [
    %{name: "recall", arg_hint: "<locus>", desc: "graph neighbors of the locus"},
    %{name: "history", arg_hint: "<locus>", desc: "recent events at the locus"},
    %{name: "outcomes", arg_hint: "<locus>", desc: "success/error ledger for the locus"},
    %{name: "explain", arg_hint: "<text>", desc: "FINISH with a one-line hypothesis"}
  ]

  # Per-site few-shot examples. Key = decision site; value = one-shot demo that
  # forces the CALL format. Keep examples on loci that are NOT in the eval's
  # held-out set (no leakage).
  @sites %{
    drift: {"surprise spike on app.executed, 2x baseline over 20 events", "CALL history app.executed"}
  }

  @doc "The diagnostic toolset (exposed for the held-out eval so it tests the SHIPPED prompt)."
  def tools, do: @tools

  @doc "The one-shot example for a decision site (exposed for the eval — no drift)."
  def example(site \\ :drift), do: Map.fetch!(@sites, site)

  @doc """
  Fire-and-forget on a drift alarm. `locus` is the drifting event locus;
  `ctx` carries `%{fast, slow}` surprise bits. Always returns `:ok` immediately —
  the decision + emit happen in a supervised task, or not at all when the
  micro-brain is disabled/absent.
  """
  def on_alarm(locus, ctx) when is_binary(locus) do
    if Autopoet.Micro.enabled?() do
      Task.Supervisor.start_child(Nexus.Events.TaskSup, fn -> run(locus, ctx) end)
    end

    :ok
  end

  # The task body: gate on availability, decide, emit the enriched attention.
  defp run(locus, ctx) do
    case suggest(locus, ctx) do
      {:ok, action} ->
        Autopoet.Log.puts("triage: drift on #{locus} → CALL #{action.tool} #{action.arg}")

        Nexus.Events.emit(%{
          kind: "autopoet.attention.triaged",
          reason: "drift",
          locus: locus,
          tool: action.tool,
          arg: action.arg,
          fast: ctx[:fast],
          slow: ctx[:slow]
        })

      _ ->
        :ok
    end
  end

  @doc """
  The micro-brain's first diagnostic action for a drift on `locus` — the pure,
  testable core (the held-out eval drives this). Returns:

    * `{:ok, %{tool, arg, raw}}` — a decision, `tool` ∈ the diagnostic toolset
    * `:unavailable` — the model is down (caller degrades)
    * `:none` — the model answered but emitted nothing parseable
  """
  def suggest(locus, ctx) when is_binary(locus) do
    if Autopoet.Micro.available?() do
      fast = fmt(ctx[:fast])
      slow = fmt(ctx[:slow])

      situation =
        "surprise drift on #{locus} (fast #{fast} bits vs slow #{slow} baseline; the stream " <>
          "just got materially more surprising here). Pick the first diagnostic action."

      Autopoet.Micro.decide(situation, @tools, example: example(:drift))
    else
      :unavailable
    end
  end

  defp fmt(n) when is_float(n), do: Float.round(n, 2)
  defp fmt(n) when is_number(n), do: n
  defp fmt(_), do: 0
end
