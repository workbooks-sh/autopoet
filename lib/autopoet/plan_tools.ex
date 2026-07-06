defmodule Autopoet.PlanTools do
  @moduledoc """
  The onboarding brain's TOOLS — the SAME kit a regular Nexus agent has, exposed
  as one-shot round-trips the conversation can drive via "moves".

  `bash/1` runs ONE agent command line on the real Washy shell (`Nexus.Agent.Bash`,
  coreutils + host web verbs) in a throwaway sandbox seeded with the autopoet
  skill + guide pages — so `ls skills`, `cat skills/<name>.md`, `grep`,
  `search <query>`, and `scrape <url>` all work, exactly like the agent loop.
  Skills come from `Autopoet.Guide` (the seeded skill--* pages); `SkillKB` is the
  cloud/dogfood path and isn't materialised in this checkout.
  """

  @grant %{grant: ["web", "net", "browse"], depth: 0}

  @doc "Run one agent bash line; returns {:ok, stdout} | {:error, msg}."
  def bash(line) when is_binary(line) do
    line = String.trim(line)

    if line == "" do
      {:ok, ""}
    else
      vfs = Nexus.Agent.Vfs.new()

      try do
        seed(vfs)
        out = Nexus.Agent.Bash.run(vfs, line, @grant)
        {:ok, out |> to_string() |> String.slice(0, 6000)}
      rescue
        e -> {:error, Exception.message(e)}
      after
        Nexus.Agent.Vfs.destroy(vfs)
      end
    end
  end

  def bash(_), do: {:error, "no command"}

  # seed every guide page into /work so the shell can read them: skill--* pages
  # under skills/, the rest under guide/ (the agent's readable knowledge world)
  defp seed(vfs) do
    for name <- Autopoet.Guide.pages() do
      dir = if String.starts_with?(name, "skill--"), do: "skills", else: "guide"
      Nexus.Agent.Vfs.put(vfs, "#{dir}/#{name}.md", Autopoet.Guide.read(name) || "")
    end
  end

  @doc """
  The skills catalog — one line per skill (`- skill--name: summary`) — injected
  into the brain's prompt so it KNOWS what skills exist and can `cat` the right one.
  """
  def skills_catalog do
    Autopoet.Guide.index()
    |> to_string()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "- skill--"))
    |> Enum.join("\n")
  rescue
    _ -> ""
  end
end
