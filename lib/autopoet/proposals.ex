defmodule Autopoet.Proposals do
  @moduledoc """
  The human gate — v3 is PROPOSAL-ONLY. Every change the brain produces lands here
  as plain files under `data/proposals/<id>/` (item.txt, status, changes/<relpath>);
  nothing touches the workbook tree except `accept/2`, which re-runs the REAL merge
  gate (`Nexus.Autopoet.Eval.validate/2`) at accept time and refuses failing or
  path-escaping change sets. accept/reject emit labeled events onto the bus — the
  B9/B4 labeled stream the production hypotheses need.
  """

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "proposals"])

  @doc "Record a proposal. Returns its id. Change paths are sanitized (no traversal) BEFORE anything is written — an unsafe set leaves no zombie proposal behind."
  def record(item, changes) when is_map(changes) do
    for {rel, _} <- changes, do: sanitize!(rel)

    id = "p#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
    base = Path.join(dir(), id)
    File.mkdir_p!(Path.join(base, "changes"))
    File.write!(Path.join(base, "item.txt"), inspect(item, pretty: true) <> "\n")
    File.write!(Path.join(base, "status"), "pending\n")

    for {rel, src} <- changes do
      rel = sanitize!(rel)
      target = Path.join([base, "changes", rel])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, src)
    end

    Nexus.Events.emit(%{kind: "proposal.recorded", proposal: id, target: item[:target], tags: []})
    Autopoet.Log.puts("PROPOSAL #{id} recorded for #{item[:target]} (#{map_size(changes)} file(s)) — autopoetctl accept #{id}")
    id
  end

  def list do
    for base <- Path.wildcard(Path.join(dir(), "p*")), File.dir?(base) do
      {Path.basename(base), base |> Path.join("status") |> File.read!() |> String.trim()}
    end
  end

  def changes(id) do
    base = Path.join([dir(), sanitize!(id), "changes"])

    for f <- Path.wildcard(Path.join(base, "**/*")), File.regular?(f), into: %{} do
      {Path.relative_to(f, base), File.read!(f)}
    end
  end

  @doc """
  Apply a pending proposal to `root` — through the real Eval gate. Human-only path.
  Every file about to be replaced is snapshotted into `<id>/replaced/` (new files
  recorded in `<id>/absent.list`), so an accidental accept is undoable via revert/2.
  """
  def accept(id, root) do
    with "pending" <- status(id),
         changes = changes(id),
         %{verdict: :pass} = verdict <- Nexus.Autopoet.Eval.validate(root, changes) do
      base = Path.join(dir(), sanitize!(id))

      for {rel, src} <- changes do
        rel = sanitize!(rel)
        target = Path.join(root, rel)

        if File.exists?(target) do
          backup = Path.join([base, "replaced", rel])
          File.mkdir_p!(Path.dirname(backup))
          File.cp!(target, backup)
        else
          File.write!(Path.join(base, "absent.list"), rel <> "\n", [:append])
        end

        File.mkdir_p!(Path.dirname(target))
        File.write!(target, src)
      end

      set_status(id, "accepted")
      Nexus.Events.emit(%{kind: "proposal.accepted", proposal: id, tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} ACCEPTED (#{map_size(changes)} file(s) applied; autonomy was #{verdict.autonomy})")
      :ok
    else
      %{verdict: :fail} = v ->
        set_status(id, "rejected-by-gate")
        Autopoet.Log.puts("PROPOSAL #{id} refused by the Eval gate: #{inspect(v.parse_errors)}")
        {:error, :gate_failed}

      other ->
        {:error, other}
    end
  end

  @doc "Undo an accepted proposal: restore replaced files, remove files it created. The gate's human safety net for misclicks."
  def revert(id, root) do
    with "accepted" <- status(id) do
      base = Path.join(dir(), sanitize!(id))

      created =
        case File.read(Path.join(base, "absent.list")) do
          {:ok, body} -> String.split(body, "\n", trim: true)
          _ -> []
        end

      for rel <- created, do: File.rm(Path.join(root, sanitize!(rel)))

      replaced = Path.join(base, "replaced")

      restored =
        for f <- Path.wildcard(Path.join(replaced, "**/*")), File.regular?(f) do
          rel = Path.relative_to(f, replaced)
          target = Path.join(root, rel)
          File.mkdir_p!(Path.dirname(target))
          File.cp!(f, target)
          rel
        end

      set_status(id, "reverted")
      Nexus.Events.emit(%{kind: "proposal.reverted", proposal: id, tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} REVERTED (#{length(restored)} restored, #{length(created)} removed)")
      :ok
    else
      other -> {:error, other}
    end
  end

  def reject(id) do
    with "pending" <- status(id) do
      set_status(id, "rejected")
      Nexus.Events.emit(%{kind: "proposal.rejected", proposal: id, tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} rejected")
      :ok
    else
      other -> {:error, other}
    end
  end

  def status(id), do: [dir(), sanitize!(id), "status"] |> Path.join() |> File.read!() |> String.trim()

  defp set_status(id, status), do: File.write!(Path.join([dir(), sanitize!(id), "status"]), status <> "\n")

  defp sanitize!(rel) do
    rel = to_string(rel)

    if String.starts_with?(rel, "/") or String.contains?(rel, "..") do
      raise ArgumentError, "unsafe path: #{rel}"
    end

    rel
  end
end
