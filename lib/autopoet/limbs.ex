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

  defp run_research(question) do
    {:ok, handoff} =
      Nexus.Autopoet.Plan.handoff(%{
        title: "research: #{question}",
        task: question,
        context: "You are an ephemeral limb of this nexus's autopoet. Report back and vanish.",
        acceptance: "findings as sourced bullets + 3-line summary"
      })

    case Nexus.Agent.run_named(:research_limb, Nexus.Autopoet.Plan.render(handoff)) do
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
        Autopoet.Log.puts("limb failed: #{inspect(reason)}")
    end
  end

  defp safe_parse(f) do
    Nexus.Literate.parse(File.read!(f))
  rescue
    _ -> []
  end
end
