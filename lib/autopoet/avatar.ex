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

  def default_seed, do: System.get_env("AUTOPOET_SEED") || "autopoet-1"

  @doc """
  The face — deliberately MINIMAL: just the eyes and mouth as line art on a
  transparent ground (the white squircle shows through). No skin/hair/ears/beard/
  background — this is the nexus's single brand face, not a random identity.
  Nested groups let the page blink the eyes, swap the mouth, and parallax the whole
  face toward the cursor (`#ap-face` base shift, `#ap-eyes-px` extra eye depth).
  """
  def svg(_seed \\ default_seed(), size \\ 280) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="#{size}" height="#{size}" fill="none" shape-rendering="auto" preserveAspectRatio="xMidYMid meet">
    <g id="ap-face" style="transition:transform .12s ease-out">
      <g id="ap-eyes-px" style="transition:transform .12s ease-out">
        <g id="ap-eyes" style="transform-box:fill-box;transform-origin:center;transition:transform .09s ease">#{File.read!(base_path("eyes"))}</g>
      </g>
      <g id="ap-mouth" transform="translate(0 2)">#{part("mood", "neutral")}</g>
    </g>
    </svg>
    """
  end

  @doc "Every mouth expression, keyed by mood — the page swaps these for emotion + talking."
  def mouths, do: Map.new(@moods, fn m -> {m, part("mood", m)} end)

  @doc "Moods available (neutral first)."
  def moods, do: @moods

  # ── parts ────────────────────────────────────────────────────────────────────

  defp part(group, name), do: File.read!(Path.join([dir(), group, name <> ".svg"]))
  defp base_path(name), do: Path.join(dir(), name <> ".svg")
  defp dir, do: Path.join(:code.priv_dir(:autopoet), "avatar-dylan")
end
