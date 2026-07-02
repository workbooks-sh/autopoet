defmodule Autopoet.Notes do
  @moduledoc """
  The human's VAULT — the source of truth the autopoet learns from (the typeaway
  model instantiated as the standard lane). Exactly two file kinds, Obsidian-style:

    * `.md`          — natural-language documents (plain thoughts, plans, rules)
    * `.sketch.svg`  — freehand drawings (stroke paths drawn in the app)

  The vault holds NO `.work` files — `.work` is the TRANSLATION TARGET (visible as
  the world graph), never shown here. On save, a note whose content actually
  changed files a typed translation request (diff-triggered; the request queue
  keys by target, so rapid edits collapse to the latest). The next heartbeat's
  brain — planner + Mercury, the audited typeaway two-model pattern — proposes
  minimal `.work` changes through the normal human gate.
  """

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "notes"])
  def state_dir, do: Path.join([Autopoet.Discovery.home(), "data", "notes-state"])

  @doc """
  Seed the vault with a welcome note — ONLY into a truly empty vault. (Checking
  just the root path re-created welcome.md after the human moved it into a
  folder; the vault is theirs to arrange.)
  """
  def seed do
    File.mkdir_p!(dir())
    File.mkdir_p!(state_dir())
    welcome = Path.join(dir(), "welcome.md")

    if Path.wildcard(Path.join(dir(), "**/*")) == [] do
      File.write!(welcome, """
      Welcome to your vault.

      Write plain thoughts here — documents and sketches are your source of truth.
      When you save, the autopoet translates your intent into its own structures
      and files a proposal for you to approve on the graph. It never edits these
      notes; they are yours.
      """)
    end

    :ok
  end

  @doc """
  The vault as a tree of %{name, path, type: folder|note|sketch, children?} in
  SET-LIST order (human-arranged via drag-drop; per-dir order persisted in
  notes-state; unknown entries append in filesystem order).
  """
  def tree, do: build_tree(dir(), "")

  defp build_tree(abs, rel) do
    case File.ls(abs) do
      {:ok, entries} ->
        entries = entries |> Enum.reject(&String.starts_with?(&1, ".")) |> apply_order(rel)

        for entry <- entries do
          a = Path.join(abs, entry)
          r = if rel == "", do: entry, else: rel <> "/" <> entry

          if File.dir?(a) do
            # a workspace is a folder marked with a .workspace file — a grouping (shown
            # with # in the tree, like the Nexus `workspaces=` subtree concept)
            type = if File.exists?(Path.join(a, ".workspace")), do: "workspace", else: "folder"
            %{name: entry, path: r, type: type, meta: meta(r), children: build_tree(a, r)}
          else
            %{name: entry, path: r, type: kind_of(a), meta: meta(r)}
          end
        end

      _ ->
        []
    end
  end

  @doc """
  A file's kind STICKS regardless of its name: extension first, else content sniff
  (a renamed sketch with no extension is still a sketch — it contains <svg).
  No extension at all = a document.
  """
  def kind_of(abs) do
    cond do
      String.ends_with?(abs, ".sketch.svg") -> "sketch"
      String.ends_with?(abs, ".md") -> "note"
      sniff_svg?(abs) -> "sketch"
      true -> "note"
    end
  end

  defp sniff_svg?(abs) do
    case File.open(abs, [:read], &IO.binread(&1, 200)) do
      {:ok, head} when is_binary(head) -> head |> String.trim_leading() |> String.starts_with?("<svg")
      _ -> false
    end
  end

  def kind(name) do
    if String.ends_with?(name, ".sketch.svg"), do: "sketch", else: "note"
  end

  # ── set-list ordering ─────────────────────────────────────────────────────

  defp order_path(rel_dir),
    do: Path.join(state_dir(), "order-" <> Base.url_encode64(rel_dir, padding: false) <> ".txt")

  @doc "Persist the human's arrangement of a directory (one name per line)."
  def reorder(rel_dir, names) when is_list(names) do
    File.mkdir_p!(state_dir())
    File.write!(order_path(rel_dir), Enum.join(names, "\n") <> "\n")
    :ok
  end

  defp apply_order(entries, rel_dir) do
    case File.read(order_path(rel_dir)) do
      {:ok, body} ->
        order = String.split(body, "\n", trim: true)
        ranked = Enum.with_index(order) |> Map.new()
        Enum.sort_by(entries, fn e -> Map.get(ranked, e, 1_000_000) end)

      _ ->
        entries
    end
  end

  # ── rename / delete (real actions behind the context menu) ────────────────

  def rename(from, to) do
    src = safe!(from)
    dst = safe!(to)

    if File.exists?(src) and not File.exists?(dst) do
      File.mkdir_p!(Path.dirname(dst))
      :ok = File.rename(src, dst)
      # the diff-state follows the file loosely: drop the old hash (a future save
      # under the new name re-baselines)
      File.rm(Path.join(state_dir(), Base.url_encode64(from, padding: false)))
      # metadata (type/icon/tags) follows the item to its new name
      case File.read(meta_path(from)) do
        {:ok, body} -> File.write!(meta_path(to), body); File.rm(meta_path(from))
        _ -> :ok
      end
      Autopoet.Log.puts("vault: renamed #{from} → #{to}")
      :ok
    else
      {:error, :bad_rename}
    end
  end

  def delete(rel) do
    p = safe!(rel)

    if File.exists?(p) or File.dir?(p) do
      File.rm_rf!(p)
      File.rm(Path.join(state_dir(), Base.url_encode64(rel, padding: false)))
      File.rm(meta_path(rel))
      Autopoet.Log.puts("vault: deleted #{rel}")
      :ok
    else
      {:error, :not_found}
    end
  end

  def read(rel), do: File.read(safe!(rel))

  @doc "Save a note; if its content actually changed, file the translation request."
  def write(rel, content) do
    p = safe!(rel)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, content)
    # a "context" item is pure read-only reference — it never instantiates .work;
    # everything else (default "literate") translates on change, the typeaway lane
    if meta(rel)["type"] != "context", do: maybe_translate(rel, content)
    :ok
  end

  @doc """
  Create an empty note/sketch/folder/workspace (never overwrites). `meta` carries
  the vault-item metadata chosen in the new-item modal: `type` (literate | context),
  `icon` (a VS Code Material icon name), and `tags`.
  """
  def create(rel, kind, meta \\ %{}) do
    p = safe!(rel)

    if File.exists?(p) do
      {:error, :exists}
    else
      with :ok <- do_create(p, kind) do
        if meta != %{}, do: set_meta(rel, meta)
        :ok
      end
    end
  end

  # ── per-item metadata (type / icon / tags) — a line-based sidecar in notes-state,
  # NOT json: it's app metadata, kept out of the human's note content ─────────────
  def meta_path(rel), do: Path.join(state_dir(), "meta-" <> Base.url_encode64(rel, padding: false))

  @doc "Read an item's metadata: %{\"type\", \"icon\", \"tags\" => [..]} (empty defaults if unset)."
  def meta(rel) do
    case File.read(meta_path(rel)) do
      {:ok, body} ->
        kv =
          for line <- String.split(body, "\n", trim: true),
              [k, v] <- [String.split(line, ":", parts: 2)],
              into: %{},
              do: {String.trim(k), String.trim(v)}

        %{
          "type" => kv["type"],
          "icon" => (kv["icon"] || "") |> nil_if_blank(),
          "tags" => (kv["tags"] || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        }

      _ ->
        %{"type" => nil, "icon" => nil, "tags" => []}
    end
  end

  @doc "Write an item's metadata sidecar."
  def set_meta(rel, m) do
    File.mkdir_p!(state_dir())
    tags = m["tags"] || m[:tags] || []
    body = "type: #{m["type"] || m[:type] || "program"}\n" <>
             "icon: #{m["icon"] || m[:icon] || ""}\n" <>
             "tags: #{Enum.join(tags, ", ")}\n"
    File.write!(meta_path(rel), body)
    :ok
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp do_create(p, "folder") do
    File.mkdir_p!(p)
    :ok
  end

  # a workspace is a folder + a .workspace marker (a grouping in the tree, shown with #)
  defp do_create(p, "workspace") do
    File.mkdir_p!(p)
    File.write!(Path.join(p, ".workspace"), "")
    :ok
  end

  defp do_create(p, "sketch") do
    File.mkdir_p!(Path.dirname(p))

    File.write!(p, """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 800" fill="none">
    </svg>
    """)

    :ok
  end

  defp do_create(p, _note) do
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, "")
    :ok
  end

  # ── diff-triggered translation ────────────────────────────────────────────────

  defp maybe_translate(rel, content) do
    hash = :erlang.md5(content) |> Base.encode16()
    state = Path.join(state_dir(), Base.url_encode64(rel, padding: false))
    old = case File.read(state) do
      {:ok, h} -> h
      _ -> nil
    end

    if old != hash do
      File.write!(state, hash)
      Autopoet.Requests.file("notes/#{rel}", translation_request(rel, kind(Path.basename(rel)), content))
      Autopoet.Log.puts("vault: #{rel} changed — translation queued")
    end

    :ok
  end

  defp translation_request(rel, "note", content) do
    """
    TRANSLATE A HUMAN NOTE (the vault is the source of truth; this note changed): notes/#{rel}
    Derive the MINIMAL .work changes that realize the note's intent — pages, todos,
    hooks, rules, whatever the note implies. Notes are never .work files and never
    appear in the body; only the derived structures do. If the note implies nothing
    actionable yet, propose nothing.

    NOTE CONTENT:
    #{String.slice(content, 0, 6000)}
    """
  end

  defp translation_request(rel, "sketch", content) do
    """
    TRANSLATE A HUMAN SKETCH (the vault is the source of truth; this drawing changed): notes/#{rel}
    Below is the sketch as raw SVG strokes. Interpret shapes, arrows, and any drawn
    words best-effort; derive the MINIMAL .work changes the drawing implies. If it
    is not yet interpretable, propose nothing.

    SKETCH SVG:
    #{String.slice(content, 0, 6000)}
    """
  end

  defp safe!(rel) do
    rel = to_string(rel)

    if String.starts_with?(rel, "/") or String.contains?(rel, ".."),
      do: raise(ArgumentError, "unsafe path: #{rel}")

    Path.join(dir(), rel)
  end
end
