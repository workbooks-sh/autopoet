defmodule Autopoet.Avatar do
  @moduledoc """
  The face of the nexus — composed 100% locally from the vendored notionists-neutral
  part library (Notionists by Zoish, CC0 1.0; extracted into categorized fragments
  under `priv/avatar/<group>/<variant>.svg` by `vendor/extract.mjs`; no API calls,
  ever). **Glasses are deliberately excluded** from composition (the parts stay on
  disk for future curation).

  A seed deterministically picks one variant per part (`phash2({seed, group})`), so
  the same seed is the same face forever. Default seed comes from AUTOPOET_SEED or
  the stable `"autopoet-1"` — the face of this nexus, not a new stranger per boot.

  Without glasses: 30 lips x 20 noses x 5 eyes x 13 brows = 39,000 distinct faces.
  """

  # Draw order + per-group transforms, verbatim from the style's create() (index.js).
  # Glasses (translate(-45 137), between eyes and brows) intentionally absent.
  @layout [
    {"lips", "translate(136 328)"},
    {"nose", "translate(246 125)"},
    {"eyes", "translate(-45 137)"},
    {"brows", "translate(119 114)"}
  ]

  @doc "Compose the avatar SVG for `seed` (deterministic) at `size` px."
  def svg(seed \\ default_seed(), size \\ 280) do
    body =
      Enum.map_join(@layout, "", fn {group, transform} ->
        ~s(<g transform="#{transform}">#{fragment(group, seed)}</g>)
      end)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 560" width="#{size}" height="#{size}" fill="none" shape-rendering="auto">#{body}</svg>
    """
  end

  def default_seed, do: System.get_env("AUTOPOET_SEED") || "autopoet-1"

  @doc "The variant names available for a part group (sorted, from priv/avatar)."
  def variants(group) do
    [parts_dir(), group, "*.svg"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".svg"))
    |> Enum.sort()
  end

  defp fragment(group, seed) do
    variants = variants(group)
    pick = Enum.at(variants, :erlang.phash2({seed, group}, length(variants)))
    File.read!(Path.join([parts_dir(), group, pick <> ".svg"]))
  end

  defp parts_dir, do: Path.join(:code.priv_dir(:autopoet), "avatar")
end
