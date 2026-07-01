defmodule Autopoet.Guide do
  @moduledoc """
  Progressive disclosure for the brain — the autopoet's guide to autopoiesis.

  Deep `.work`/nexus reference pages live IN the body (`<data>/guide/*.work`,
  seeded from the authoring skill's references + the autopoet house rules), so the
  guide is itself proposable-against. The planner sees only a one-line-per-page
  index and requests depth with `NEED: <page>` lines; the requested pages are
  loaded into a second planning round and passed through to the drafter.
  """

  def dir, do: Path.join(Nexus.Paths.data_dir(), "guide")

  @doc "Copy the packaged guide pages into the body (never overwrites)."
  def seed do
    src = Path.join(:code.priv_dir(:autopoet), "guide")
    File.mkdir_p!(dir())

    for f <- Path.wildcard(Path.join(src, "*.work")),
        target = Path.join(dir(), Path.basename(f)),
        not File.exists?(target) do
      File.cp!(f, target)
    end

    :ok
  end

  def pages do
    dir()
    |> Path.join("*.work")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".work"))
    |> Enum.sort()
  end

  @doc "One line per page: `- name: first prose line` — the always-in-context index."
  def index do
    Enum.map_join(pages(), "\n", fn name -> "- #{name}: #{summary(name)}" end)
  end

  @doc "Full page content by name (sanitized — name only, no paths), or nil."
  def read(name) do
    clean = name |> to_string() |> Path.basename() |> String.trim_trailing(".work")
    path = Path.join(dir(), clean <> ".work")
    if File.exists?(path), do: File.read!(path)
  end

  defp summary(name) do
    (read(name) || "")
    |> String.split("\n")
    |> Enum.find("", fn l ->
      t = String.trim(l)
      t != "" and not String.starts_with?(t, "#") and not String.starts_with?(t, "<!--")
    end)
    |> String.slice(0, 110)
  end
end
