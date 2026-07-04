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

  @doc """
  Record a proposal. Returns its id. `changes` are whole-file writes; `appends` are
  bodies added to a file's END at accept time (the safe mode — the drafter never
  has to reproduce existing content, so placeholder-stub clobbering is impossible).
  All paths sanitized BEFORE anything is written — an unsafe set leaves no zombie.
  """
  def record(item, changes, appends \\ %{}) when is_map(changes) and is_map(appends) do
    for {rel, _} <- changes, do: sanitize!(rel)
    for {rel, _} <- appends, do: sanitize!(rel)

    id = "p#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
    base = Path.join(dir(), id)
    File.mkdir_p!(Path.join(base, "changes"))
    File.write!(Path.join(base, "item.txt"), inspect(item, pretty: true) <> "\n")
    File.write!(Path.join(base, "status"), "pending\n")
    File.write!(Path.join(base, "target"), to_string(item[:target] || "?") <> "\n")

    for {kind, map} <- [{"changes", changes}, {"appends", appends}], {rel, src} <- map do
      target = Path.join([base, kind, sanitize!(rel)])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, src)
    end

    n = map_size(changes) + map_size(appends)
    Nexus.Events.emit(%{kind: "proposal.recorded", proposal: id, target: item[:target], tags: []})
    Autopoet.Log.puts("PROPOSAL #{id} recorded for #{item[:target]} (#{n} file(s)) — autopoetctl accept #{id}")
    id
  end

  def list do
    for base <- Path.wildcard(Path.join(dir(), "p*")), File.dir?(base) do
      {Path.basename(base), base |> Path.join("status") |> File.read!() |> String.trim()}
    end
  end

  @doc "Proposals awaiting a decision — the ephemeral inbox. Resolved ones stay on disk for revert/audit but are not active state."
  def pending, do: list() |> Enum.filter(fn {_, s} -> s == "pending" end)

  def changes(id), do: read_set(id, "changes")
  def appends(id), do: read_set(id, "appends")

  @doc "The proposal's declared target locus (recorded at record time) — reward events carry it so the outcome ledger keys by locus, not proposal id."
  def target_of(id) do
    case File.read(Path.join([dir(), sanitize!(id), "target"])) do
      {:ok, body} -> String.trim(body)
      _ -> "?"
    end
  end

  defp read_set(id, kind) do
    base = Path.join([dir(), sanitize!(id), kind])

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
         changes = compose(id, root),
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
      Nexus.Events.emit(%{kind: "proposal.accepted", proposal: id, target: target_of(id), tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} ACCEPTED (#{map_size(changes)} file(s) applied; autonomy was #{verdict.autonomy})")

      # hot-reload: an accepted agent definition registers immediately (limbs
      # otherwise only register at boot — an accepted organ must come alive now)
      if Enum.any?(changes, fn {_, src} -> src =~ ~r/^agent :/m end) do
        Autopoet.Limbs.register_from_body()
      end

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
      Nexus.Events.emit(%{kind: "proposal.reverted", proposal: id, target: target_of(id), tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} REVERTED (#{length(restored)} restored, #{length(created)} removed)")
      :ok
    else
      other -> {:error, other}
    end
  end

  def reject(id, reason \\ nil) do
    with "pending" <- status(id) do
      if is_binary(reason) and reason != "" do
        File.write!(Path.join([dir(), sanitize!(id), "reason"]), reason <> "\n")
      end

      set_status(id, "rejected")
      Nexus.Events.emit(%{kind: "proposal.rejected", proposal: id, target: target_of(id), reason: reason, tags: []})
      Autopoet.Log.puts("PROPOSAL #{id} rejected#{if reason, do: " — #{reason}", else: ""}")
      :ok
    else
      other -> {:error, other}
    end
  end

  # Appends resolve against the CURRENT file at accept time (the gate validates the
  # composed result), so a drift between record and accept can never lose content.
  defp compose(id, root) do
    appended =
      Map.new(appends(id), fn {rel, body} ->
        existing =
          case File.read(Path.join(root, sanitize!(rel))) do
            {:ok, s} -> if String.ends_with?(s, "\n"), do: s, else: s <> "\n"
            _ -> ""
          end

        {rel, existing <> body}
      end)

    Map.merge(changes(id), appended)
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
