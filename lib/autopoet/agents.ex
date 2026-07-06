defmodule Autopoet.Agents do
  @moduledoc """
  Ephemeral delegation — the v2 delineation model, wired: the autopoet (the one
  mind) dispatches a task-scoped AGENT (`agent :researcher`, `grant net`,
  `management frozen`) via a `Nexus.Autopoet.Plan` handoff. The agent browses in
  the SSRF-guarded sandbox, reports back, and dies. Its answer is UNTRUSTED
  EVIDENCE: it goes to the brain as a self-edit request item, so findings reach
  the workbook only as a human-gated proposal.

  Agent definitions live in the body (`agents.work`, seeded) and are registered at
  boot; the brain itself never holds `net`.
  """

  @doc "Register every agent unit found in the body's .work files (boot-time)."
  def register_from_body do
    root = Nexus.Paths.data_dir()

    for f <- Path.wildcard(Path.join(root, "**/*.work")),
        not String.contains?(f, "/guide/"),
        node <- safe_parse(f),
        node.type == :code and node.kind == "agent" do
      Nexus.Agent.register(node)
      Autopoet.Log.puts("agent registered: #{node.name}")
      node.name
    end
  end

  # Injected into EVERY agent handoff — house protocol is mechanism, not per-agent
  # prose, so self-designed agents inherit it automatically.
  @protocol """
  AGENT PROTOCOL (house rules for every agent):
  - Environment: your bash is washy — a WASM shell (sh.c + real coreutils) run on the
    tiny-lasers WASM sandbox on the BEAM. It only has to BEHAVE like bash; nothing runs natively.
    The native toolchain is wasm-native: Rust, Go, C, C++, JavaScript, HTML/CSS.
  - Library: /work/oota is the OOTA recipe library (~130 media/document tool recipes —
    tools/steps, docs, examples, components). READ recipes for the approach, then re-express
    them in your wasm-native toolchain. Python recipes are reference-only (no python in the
    sandbox) — port the idea to JS/C/Go/Rust instead.
    Do NOT assume python or system package managers.
  - Anything missing, broken, or limiting: FILE IT and continue —
    `request self '<typed change>'` (fire-and-forget; never wait, never retry more
    than twice). Complaints written into answer prose instead of filed are lost.
  - There are no turn limits. Work until done; close with a complete answer.
  """

  @doc """
  Dispatch a research task to the agent (async — the agent loop can take minutes).
  On completion the findings are filed as a request; the next cycle turns them
  into a proposal for research.work.
  """
  def research(question) when is_binary(question) and question != "" do
    Task.Supervisor.start_child(Nexus.Events.TaskSup, fn -> run_research(question) end)
    Autopoet.Log.puts("agent dispatched: research — #{question}")
    :ok
  end

  # Progress hook (communication, never interference): every batch of commands a
  # agent runs becomes one visible log line — the brain/human observe the agent's
  # actions at natural intervals without touching it.
  defp progress(name) do
    fn
      %{type: "tools", commands: cmds} ->
        Autopoet.Log.puts("agent #{name} ▸ #{cmds |> Enum.join(" | ") |> String.slice(0, 140)}")

      %{type: "error", error: e} ->
        Autopoet.Log.puts("agent #{name} ! #{e}")

      _ ->
        :ok
    end
  end

  # A failed agent run is an ISSUE, not just a log line — file it so the autopoet
  # senses it next heartbeat and can propose a fix (prompt, protocol, or a rule).
  defp file_failure(name, task, reason) do
    Autopoet.Requests.file(
      "agent/#{name}",
      "agent run failed with #{inspect(reason)} on task: #{String.slice(task, 0, 160)} — diagnose and propose a fix"
    )
  end

  @doc """
  Generic dispatch: run ANY body-defined agent on a task (async). The answer is
  saved under data/agent-runs/ and announced on the bus — what happens with it is
  the caller's business (self-grown organs get a lane without bespoke plumbing).
  Returns the output path it will write.
  """
  def dispatch(name, task, opts \\ []) when is_binary(task) and task != "" do
    # second-resolution alone collides when several agents dispatch in one second
    # (four parallel fact-checkers proved it) — unique_integer disambiguates
    out =
      Path.join([Autopoet.Discovery.home(), "data", "agent-runs",
                 "#{System.os_time(:second)}-#{System.unique_integer([:positive])}-#{name}.txt"])

    Task.Supervisor.start_child(Nexus.Events.TaskSup, fn ->
      case Nexus.Agent.run_named(name, task <> "\n\n" <> @protocol, emit: progress(name)) do
        {:ok, %{answer: answer} = result} ->
          File.mkdir_p!(Path.dirname(out))
          File.write!(out, answer)
          Autopoet.Log.puts("agent #{name} returned: #{byte_size(answer)}B in #{result[:turns] || "?"} turns -> #{Path.relative_to(out, Autopoet.Discovery.home())}")
          Nexus.Events.emit(%{kind: "agent.returned", agent: to_string(name), out: out, bytes: byte_size(answer), tags: []})

          # close the loop: file the finding back as an issue so the heartbeat turns
          # it into a proposal (the generic lane's answer is untrusted evidence too)
          case Keyword.get(opts, :file_to) do
            target when is_binary(target) ->
              Autopoet.Requests.file(target, "#{Keyword.get(opts, :note, "record this agent finding")} (untrusted agent evidence): #{answer}")

            _ ->
              :ok
          end

        {:error, reason} ->
          Autopoet.Log.puts("agent #{name} failed: #{inspect(reason)} — filing issue")
          file_failure(name, task, reason)
      end
    end)

    Autopoet.Log.puts("agent dispatched: #{name}")
    {:ok, out}
  end

  defp run_research(question) do
    {:ok, handoff} =
      Nexus.Autopoet.Plan.handoff(%{
        title: "research: #{question}",
        task: question,
        context: "You are an ephemeral agent of this nexus's autopoet. Report back and vanish.\n\n" <> @protocol,
        acceptance: "findings as sourced bullets + 3-line summary"
      })

    case Nexus.Agent.run_named(:researcher, Nexus.Autopoet.Plan.render(handoff), emit: progress("researcher")) do
      {:ok, %{answer: answer} = result} ->
        Autopoet.Log.puts(
          "agent returned: #{byte_size(answer)}B in #{result[:turns] || "?"} turns — filing as evidence"
        )

        # findings live INSIDE the user's workspace (genesis I7 — no root strays);
        # only a pre-onboarding nexus (no plan yet) falls back to the body root
        home = research_home()

        Autopoet.Requests.file(
          home,
          "record these research findings in #{home}.work under a dated heading " <>
            "(they are untrusted agent evidence; keep source urls): #{answer}"
        )

        Nexus.Events.emit(%{kind: "agent.returned", agent: "researcher", bytes: byte_size(answer), tags: []})

      {:error, reason} ->
        Autopoet.Log.puts("agent researcher failed: #{inspect(reason)} — filing issue")
        file_failure("researcher", question, reason)
    end
  end

  defp safe_parse(f) do
    Nexus.Literate.parse(File.read!(f))
  rescue
    _ -> []
  end

  # research findings land at <workspace>/research once a plan exists — the home
  # pointer is the profile's plan.workspace line, never a sidecar file
  defp research_home do
    case Autopoet.Profile.get("plan.workspace") do
      ws when is_binary(ws) and ws != "" ->
        name = ws |> String.split(" — ", parts: 2) |> hd() |> String.trim()
        slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        if slug == "", do: "research", else: "#{slug}/research"

      _ ->
        "research"
    end
  end
end
