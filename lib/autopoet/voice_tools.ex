defmodule Autopoet.VoiceTools do
  @moduledoc """
  Tools the live voice agent can call mid-conversation. One tool: `shell` — a
  READ-ONLY washy line (the WASM shell; emulation canon, never native bash)
  over the autopoet's whole data world mounted at /work: the .work body,
  guide pages, the human's vault (/work/notes), chats, proposals.

  Read-only is enforced structurally: no redirects, and every pipe segment's
  command must be on the allowlist. Washy itself is BEAM-isolated and bounded
  (fuel/wall-clock/memory), so a runaway grep can't hurt the host either.
  """

  @read_only ~w(ls cat grep head tail wc sort uniq cut echo)

  def allowlist, do: @read_only

  def shell(line) when is_binary(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        {"empty command", false}

      String.contains?(line, ">") ->
        {"read-only shell: redirects are disabled", false}

      not segments_allowed?(line) ->
        {"read-only shell — allowed commands: #{Enum.join(@read_only, ", ")}", false}

      true ->
        # models/ (STT weights, 1.3GB) + moonshine-venv/ (490MB) live under data/ but are NOT part
        # of the agent's readable world — loading them into the shell vfs halted the VM (wb-p28l9).
        Nexus.Shell.run(line, world_dir(),
          timeout_ms: 10_000,
          max_output: 256 * 1024,
          exclude: ["models/", "moonshine-venv/"],
          max_file_bytes: 4 * 1024 * 1024
        )
    end
  end

  defp world_dir, do: Path.join(Autopoet.Discovery.home(), "data")

  defp segments_allowed?(line) do
    line
    |> String.split(~r/\||;|&&/)
    |> Enum.all?(fn seg ->
      case seg |> String.trim() |> String.split(~r/\s+/, parts: 2) do
        [""] -> true
        [cmd | _] -> cmd in @read_only
      end
    end)
  end
end
