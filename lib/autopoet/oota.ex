defmodule Autopoet.Oota do
  @moduledoc """
  OOTA ("Out Of Thin Air", ~130 media/document tools) as a HOST-side capability of
  the autopoet app. Deliberately NOT reachable from the sandboxed limbs: OOTA's
  localhost API is SSRF-blocked in the browse lane by design, so rendering
  deliverables is something the autopoet's host shell does — the mind delegates
  research to limbs, but production of artifacts runs here, visible in the log.

  v1 is a passthrough to the `oota` CLI (Bun) in the out-of-thin-air project:
  `Autopoet.Oota.run(["route", "a one-pager about X"])` etc. Output is captured to
  the log, bounded.
  """

  @default_project "~/Apps/shinyobjectz/projects/out-of-thin-air"

  def project,
    do: Path.expand(System.get_env("AUTOPOET_OOTA_DIR") || @default_project)

  def cli, do: Path.join(project(), "oota/bin/oota.ts")

  def available?, do: File.exists?(cli()) and match?({_, 0}, System.cmd("which", ["bun"]))

  @doc "Run an oota CLI verb host-side. Returns {:ok, output} | {:error, reason}. Output bounded to 8KB."
  def run(args) when is_list(args) do
    if available?() do
      Autopoet.Log.puts("oota: #{Enum.join(args, " ")}")

      {out, code} =
        System.cmd("bun", [cli() | args],
          cd: project(),
          stderr_to_stdout: true,
          env: [{"OOTA_BASE", ""}]
        )

      out = String.slice(out, 0, 8192)
      Autopoet.Log.puts("oota exit #{code}: #{String.slice(out, 0, 300)}")
      if code == 0, do: {:ok, out}, else: {:error, {code, out}}
    else
      {:error, :oota_unavailable}
    end
  end
end
