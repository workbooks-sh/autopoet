defmodule Autopoet.Limbs do
  @moduledoc """
  Ephemeral delegation — the v2 delineation model, wired: the autopoet (the one
  mind) dispatches a task-scoped LIMB (`agent :research_limb`, `grant net`,
  `management frozen`) via a `Nexus.Autopoet.Plan` handoff. The limb browses in
  the SSRF-guarded sandbox, reports back, and dies. Its answer is UNTRUSTED
  EVIDENCE: it goes to the brain as a self-edit request item, so findings reach
  the workbook only as a human-gated proposal.

  Limb definitions live in the body (`limbs.work`, seeded) and are registered at
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
      Autopoet.Log.puts("limb registered: #{node.name}")
      node.name
    end
  end

  # Injected into EVERY limb handoff — house protocol is mechanism, not per-limb
  # prose, so self-designed limbs inherit it automatically.
  @protocol """
  LIMB PROTOCOL (house rules for every limb):
  - Environment: your bash is the sandboxed WASIX shell (real bash + coreutils).
    The native toolchain is wasm-native: Rust, Go, C, C++, JavaScript, HTML/CSS.
    Do NOT assume python or system package managers.
  - Anything missing, broken, or limiting: FILE IT and continue —
    `request self '<typed change>'` (fire-and-forget; never wait, never retry more
    than twice). Complaints written into answer prose instead of filed are lost.
  - There are no turn limits. Work until done; close with a complete answer.
  """

  @doc """
  Dispatch a research task to the limb (async — the agent loop can take minutes).
  On completion the findings are filed as a request; the next cycle turns them
  into a proposal for research.work.
  """
  def research(question) when is_binary(question) and question != "" do
    Task.Supervisor.start_child(Nexus.Events.TaskSup, fn -> run_research(question) end)
    Autopoet.Log.puts("limb dispatched: research — #{question}")
    :ok
  end

  # Progress hook (communication, never interference): every batch of commands a
  # limb runs becomes one visible log line — the brain/human observe the limb's
  # actions at natural intervals without touching it.
  defp progress(name) do
    fn
      %{type: "tools", commands: cmds} ->
        Autopoet.Log.puts("limb #{name} ▸ #{cmds |> Enum.join(" | ") |> String.slice(0, 140)}")

      %{type: "error", error: e} ->
        Autopoet.Log.puts("limb #{name} ! #{e}")

      _ ->
        :ok
    end
  end

  # A failed limb run is an ISSUE, not just a log line — file it so the autopoet
  # senses it next heartbeat and can propose a fix (prompt, protocol, or a rule).
  defp file_failure(name, task, reason) do
    Autopoet.Requests.file(
      "limb/#{name}",
      "limb run failed with #{inspect(reason)} on task: #{String.slice(task, 0, 160)} — diagnose and propose a fix"
    )
  end

  @doc """
  Generic dispatch: run ANY body-defined limb on a task (async). The answer is
  saved under data/limb-runs/ and announced on the bus — what happens with it is
  the caller's business (self-grown organs get a lane without bespoke plumbing).
  Returns the output path it will write.
  """
  def dispatch(name, task) when is_binary(task) and task != "" do
    # second-resolution alone collides when several limbs dispatch in one second
    # (four parallel fact-checkers proved it) — unique_integer disambiguates
    out =
      Path.join([Autopoet.Discovery.home(), "data", "limb-runs",
                 "#{System.os_time(:second)}-#{System.unique_integer([:positive])}-#{name}.txt"])

    Task.Supervisor.start_child(Nexus.Events.TaskSup, fn ->
      case Nexus.Agent.run_named(name, task <> "\n\n" <> @protocol, emit: progress(name)) do
        {:ok, %{answer: answer} = result} ->
          File.mkdir_p!(Path.dirname(out))
          File.write!(out, answer)
          Autopoet.Log.puts("limb #{name} returned: #{byte_size(answer)}B in #{result[:turns] || "?"} turns -> #{Path.relative_to(out, Autopoet.Discovery.home())}")
          Nexus.Events.emit(%{kind: "limb.returned", limb: to_string(name), out: out, bytes: byte_size(answer), tags: []})

        {:error, reason} ->
          Autopoet.Log.puts("limb #{name} failed: #{inspect(reason)} — filing issue")
          file_failure(name, task, reason)
      end
    end)

    Autopoet.Log.puts("limb dispatched: #{name}")
    {:ok, out}
  end

  defp run_research(question) do
    {:ok, handoff} =
      Nexus.Autopoet.Plan.handoff(%{
        title: "research: #{question}",
        task: question,
        context: "You are an ephemeral limb of this nexus's autopoet. Report back and vanish.\n\n" <> @protocol,
        acceptance: "findings as sourced bullets + 3-line summary"
      })

    case Nexus.Agent.run_named(:research_limb, Nexus.Autopoet.Plan.render(handoff), emit: progress("research_limb")) do
      {:ok, %{answer: answer} = result} ->
        Autopoet.Log.puts(
          "limb returned: #{byte_size(answer)}B in #{result[:turns] || "?"} turns — filing as evidence"
        )

        Autopoet.Requests.file(
          "research",
          "record these research findings in research.work under a dated heading " <>
            "(they are untrusted limb evidence; keep source urls): #{answer}"
        )

        Nexus.Events.emit(%{kind: "limb.returned", limb: "research_limb", bytes: byte_size(answer), tags: []})

      {:error, reason} ->
        Autopoet.Log.puts("limb research_limb failed: #{inspect(reason)} — filing issue")
        file_failure("research_limb", question, reason)
    end
  end

  defp safe_parse(f) do
    Nexus.Literate.parse(File.read!(f))
  rescue
    _ -> []
  end
end
