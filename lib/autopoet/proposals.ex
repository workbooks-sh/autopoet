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

  @doc "Apply a pending proposal to `root` — through the real Eval gate. Human-only path."
  def accept(id, root) do
    with "pending" <- status(id),
         changes = changes(id),
         %{verdict: :pass} = verdict <- Nexus.Autopoet.Eval.validate(root, changes) do
      for {rel, src} <- changes do
        target = Path.join(root, sanitize!(rel))
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
