defmodule Autopoet.Body do
  @moduledoc """
  The agent's OWN structure — the `.work` body it authors. The agent writes here
  DIRECTLY and immediately (no proposal): the body is its to shape. Every write
  first snapshots the files it will touch into `data/body-history/<id>`, so any
  edit — however sweeping — is undoable.

  Contrast the VAULT (`Autopoet.Notes`): the human's source of truth, which the
  agent has NO direct write to — it can only SUGGEST edits there via a gated
  proposal ([[proposals]]). So: body = direct + undoable; vault = propose-only.

  Writes come as two maps (the drafter's output shape): `writes` (full file
  content) and `appends` (only-new-lines, composed against the current file).
  """

  def root, do: Nexus.Paths.data_dir()
  def history_dir, do: Path.join([Autopoet.Discovery.home(), "data", "body-history"])

  @doc """
  Apply direct writes + appends to the body, snapshotting first. Returns
  `{:ok, history_id}` (nil id if nothing changed). Emits an event + logs.
  """
  def apply(writes, appends \\ %{}) when is_map(writes) and is_map(appends) do
    rels = (Map.keys(writes) ++ Map.keys(appends)) |> Enum.uniq()

    if rels == [] do
      {:ok, nil}
    else
      hid = snapshot(rels)

      for {rel, content} <- writes, do: File.write!(safe!(rel), content)

      for {rel, added} <- appends do
        p = safe!(rel)
        File.mkdir_p!(Path.dirname(p))
        cur = if File.exists?(p), do: File.read!(p), else: ""
        File.write!(p, compose(cur, added))
      end

      n = length(rels)
      emit(%{kind: "body.wrote", files: rels, history: hid, tags: []})
      Autopoet.Log.puts("body: wrote #{n} file(s) directly [#{Enum.join(rels, ", ")}] — undo #{hid}")
      {:ok, hid}
    end
  end

  @doc "A single direct write (full content), snapshotted + undoable."
  def write(rel, content), do: apply(%{to_string(rel) => content})

  @doc "History entries, newest first: `[%{id, at, files}]`."
  def history do
    File.mkdir_p!(history_dir())

    history_dir()
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(history_dir(), &1)))
    |> Enum.sort(:desc)
    |> Enum.map(fn id ->
      base = Path.join(history_dir(), id)
      files = Path.wildcard(Path.join([base, "before", "**"])) |> Enum.filter(&File.regular?/1) |> length()
      absent = case File.read(Path.join(base, "absent.list")) do
        {:ok, b} -> String.split(b, "\n", trim: true)
        _ -> []
      end
      %{id: id, files: files + length(absent)}
    end)
  end

  @doc "Undo a write: restore the body to its pre-write state from a history snapshot (default: the latest)."
  def undo(id \\ :latest) do
    id = if id == :latest, do: latest_id(), else: id
    base = id && Path.join(history_dir(), id)

    cond do
      is_nil(base) or not File.dir?(base) ->
        {:error, :no_history}

      true ->
        # restore replaced files from before/
        for src <- Path.wildcard(Path.join([base, "before", "**"])), File.regular?(src) do
          rel = Path.relative_to(src, Path.join(base, "before"))
          File.mkdir_p!(Path.dirname(safe!(rel)))
          File.cp!(src, safe!(rel))
        end

        # remove files that didn't exist before the write
        for rel <- absent(base), do: File.rm(safe!(rel))

        emit(%{kind: "body.undone", history: id, tags: []})
        Autopoet.Log.puts("body: undone #{id} — restored to pre-write state")
        :ok
    end
  end

  # best-effort: a direct write must never fail because the event bus is down
  defp emit(ev) do
    Nexus.Events.emit(ev)
  rescue
    _ -> :ok
  end

  # ── snapshot ──────────────────────────────────────────────────────────────

  # capture the current bytes of each rel that EXISTS (into before/) and the list
  # of rels that DON'T (absent.list, so undo can remove newly-created files).
  defp snapshot(rels) do
    hid = "h#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
    base = Path.join(history_dir(), hid)
    File.mkdir_p!(base)

    absent =
      for rel <- rels do
        src = safe!(rel)

        if File.exists?(src) do
          dst = Path.join([base, "before", rel])
          File.mkdir_p!(Path.dirname(dst))
          File.cp!(src, dst)
          nil
        else
          rel
        end
      end
      |> Enum.reject(&is_nil/1)

    if absent != [], do: File.write!(Path.join(base, "absent.list"), Enum.join(absent, "\n") <> "\n")
    hid
  end

  defp latest_id do
    case history() do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  defp absent(base) do
    case File.read(Path.join(base, "absent.list")) do
      {:ok, b} -> String.split(b, "\n", trim: true)
      _ -> []
    end
  end

  # append mode: add only the lines not already present at the tail (idempotent-ish compose)
  defp compose(current, added) do
    cur = String.trim_trailing(current)
    add = String.trim_trailing(added)
    if cur == "", do: add <> "\n", else: cur <> "\n" <> add <> "\n"
  end

  defp safe!(rel) do
    rel = to_string(rel)

    if String.starts_with?(rel, "/") or String.contains?(rel, ".."),
      do: raise(ArgumentError, "unsafe body path: #{rel}")

    Path.join(root(), rel)
  end
end
