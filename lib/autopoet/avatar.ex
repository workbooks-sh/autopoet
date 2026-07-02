defmodule Autopoet.Avatar do
  @moduledoc """
  The face of the nexus — composed 100% locally from the vendored dylan part
  library (Dylan! by Natalia Spivak, CC BY 4.0; extracted into layers under
  `priv/avatar-dylan/` by `vendor/extract-dylan.mjs`; no API calls).

  Split for ANIMATION, matching the design intent:
    * FIXED across every avatar: the eyes (`#ap-eyes`, blinkable) — same face.
    * SEEDED-random: face shape (skin), hair, beard, and their colors (the
      colorful dylan palette). Same seed → same identity forever.
    * STATE-driven: the mouth (`#ap-mouth`) is one of dylan's 7 moods — set by
      emotion, and cycled open/closed by the page to look like it's talking.

  `svg/2` returns layered SVG with those ids so the browser can blink the eyes and
  swap the mouth; `mouths/0` gives every mouth expression for client-side swapping.
  """

  @moods ~w(neutral happy superHappy sad angry hopeful confused)
  @skins ~w(ffd6c0 c26450)
  @hairs ~w(000000 ff543d fff500 1d5dff ffffff)
  @backgrounds ~w(ffa6e6 619eff 29e051 ffd34e a78bfa 5ed3d0)

  def default_seed, do: System.get_env("AUTOPOET_SEED") || "autopoet-1"

  @doc "Layered, animatable avatar SVG for `seed` at `size` px (default mouth: neutral)."
  def svg(seed \\ default_seed(), size \\ 280) do
    skin = pick(seed, "skin", @skins)
    hair_c = pick(seed, "hair", @hairs)

    beard =
      if :erlang.phash2({seed, "beard?"}, 100) < 55 do
        colorize(part("facialHair", pick(seed, "beard", variants("facialHair"))), hair_c)
      else
        ""
      end

    hair = colorize(part("hair", pick(seed, "hairstyle", variants("hair"))), hair_c)
    bg = pick(seed, "bg", @backgrounds)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="#{size}" height="#{size}" fill="none" shape-rendering="auto" preserveAspectRatio="xMidYMid meet">
    <rect width="80" height="80" fill="##{bg}"/>
    #{colorize(File.read!(base_path("base")), nil, skin)}
    <g id="ap-eyes" style="transform-box:fill-box;transform-origin:center;transition:transform .09s ease">#{File.read!(base_path("eyes"))}</g>
    #{beard}
    <g id="ap-mouth">#{part("mood", "neutral")}</g>
    #{hair}
    </svg>
    """
  end

  @doc "Every mouth expression, keyed by mood — the page swaps these for emotion + talking."
  def mouths, do: Map.new(@moods, fn m -> {m, part("mood", m)} end)

  @doc "Moods available (neutral first)."
  def moods, do: @moods

  # ── parts ────────────────────────────────────────────────────────────────────

  defp variants(group) do
    [dir(), group, "*.svg"] |> Path.join() |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".svg")) |> Enum.sort()
  end

  defp part(group, name), do: File.read!(Path.join([dir(), group, name <> ".svg"]))
  defp base_path(name), do: Path.join(dir(), name <> ".svg")
  defp dir, do: Path.join(:code.priv_dir(:autopoet), "avatar-dylan")

  defp pick(_seed, _key, []), do: nil
  defp pick(seed, key, list), do: Enum.at(list, :erlang.phash2({seed, key}, length(list)))

  # replace the extractor's color tokens with real hex — tokens are bare (no #),
  # so we add it here (the missing # was why hair/beard rendered invisible).
  defp colorize(svg, hair_c, skin_c \\ nil) do
    svg
    |> then(&if(hair_c, do: String.replace(&1, "HAIRCOLOR", "#" <> hair_c), else: &1))
    |> then(&if(skin_c, do: String.replace(&1, "SKINCOLOR", "#" <> skin_c), else: &1))
  end
end
