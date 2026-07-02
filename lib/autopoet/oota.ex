defmodule Autopoet.Oota do
  @moduledoc """
  OOTA ("Out Of Thin Air", ~130 media/document tool recipes) as a LIBRARY the
  sandboxed agent READS — not a host process. Canon: absolutely no native
  processes; the former bun-CLI passthrough is gone.

  At boot, the reference subset of the OOTA project (tools/, docs/, examples/,
  skill/, components/, wrappers/, oota/ + the root README/index) is seeded into
  the world at `data/oota`, so limbs and the voice agent see it at `/work/oota`
  and can ls/cat/grep the recipes like any other world content.

  USING a recipe means re-expressing it inside the tiny-lasers sandbox with the
  wasm-native toolchain — JS (Porffor lane), C, C++, Go, Rust (WASIX recompile
  lane). Python does NOT exist in the sandbox: python-based recipes are readable
  reference only, until re-expressed in a supported lane.
  """

  @default_project "~/Apps/shinyobjectz/projects/out-of-thin-air"

  # reference subdirs to mirror (cli/ is 2GB of node_modules — never)
  @subdirs ~w(tools docs examples skill components wrappers oota)
  @root_files ~w(README.md index.work Justfile)
  # text/reference extensions only; .py rides as READABLE reference (not runnable in-sandbox)
  @exts ~w(.sh .md .work .ts .js .mjs .cjs .css .html .svg .json .txt .py .yaml .yml .toml)
  @skip_segments ~w(node_modules .venv-tts .git out dist build)
  @max_file 128 * 1024
  @max_total 8 * 1024 * 1024

  def project,
    do: Path.expand(System.get_env("AUTOPOET_OOTA_DIR") || @default_project)

  def available?, do: File.dir?(project())

  def dest, do: Path.join([Autopoet.Discovery.home(), "data", "oota"])

  @doc """
  Mirror the OOTA reference library into the world (idempotent, refreshed each
  boot; bounded per-file and in total). Never raises — a missing project just
  means the library isn't seeded.
  """
  def seed_reference do
    if available?() do
      {count, bytes} =
        (root_sources() ++ subdir_sources())
        |> Enum.reduce({0, 0}, fn {src, rel}, {n, total} ->
          case File.stat(src) do
            {:ok, %{size: size}} when size <= @max_file and total + size <= @max_total ->
              target = Path.join(dest(), rel)
              File.mkdir_p!(Path.dirname(target))
              File.cp!(src, target)
              {n + 1, total + size}

            _ ->
              {n, total}
          end
        end)

      Autopoet.Log.puts("oota: reference library seeded — #{count} files (#{div(bytes, 1024)}KB) at /work/oota")
    end

    :ok
  rescue
    e ->
      Autopoet.Log.puts("oota: reference seed failed (#{Exception.message(e)}) — continuing without")
      :ok
  end

  defp root_sources do
    for f <- @root_files, src = Path.join(project(), f), File.regular?(src), do: {src, f}
  end

  defp subdir_sources do
    for sub <- @subdirs,
        src <- Path.wildcard(Path.join([project(), sub, "**"])),
        File.regular?(src),
        Path.extname(src) in @exts,
        not skip?(src) do
      {src, Path.relative_to(src, project())}
    end
  end

  defp skip?(path), do: Enum.any?(@skip_segments, &String.contains?(path, "/#{&1}/"))
end
