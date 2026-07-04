defmodule Autopoet.Eval.Canary do
  @moduledoc """
  B3 contamination canary (BIG-bench convention): this GUID lives ONLY in eval
  fixtures. If it ever appears in shipped artifacts — lib/, priv/genomes,
  priv/seed, priv/guide, the body, or the vault — eval content leaked into
  something the agent ships or reads as its own, and the leak check fails loud.
  """

  @canary "autopoet-eval-canary-c9e4b1f2-7a53-4d8e-9b06-31f5a2d47e88"

  def string, do: @canary

  @doc "Directories that must NEVER contain the canary (shipped/production surfaces)."
  def forbidden_roots(app_root) do
    [
      Path.join(app_root, "lib"),
      Path.join(app_root, "priv/genomes"),
      Path.join(app_root, "priv/seed"),
      Path.join(app_root, "priv/guide"),
      Nexus.Paths.data_dir(),
      Autopoet.Notes.dir()
    ]
  end

  @doc "Scan a root for the canary; returns offending paths."
  def leaks(root) do
    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn f ->
      case File.read(f) do
        {:ok, body} -> String.contains?(body, @canary)
        _ -> false
      end
    end)
  end
end
