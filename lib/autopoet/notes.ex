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

  @doc "Seed the vault with a welcome note (never overwrites)."
  def seed do
    File.mkdir_p!(dir())
    File.mkdir_p!(state_dir())
    welcome = Path.join(dir(), "welcome.md")

    unless File.exists?(welcome) do
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

  @doc "The vault as a tree of %{name, path, type: folder|note|sketch, children?}."
  def tree, do: build_tree(dir(), "")

  defp build_tree(abs, rel) do
    case File.ls(abs) do
      {:ok, entries} ->
        for entry <- Enum.sort(entries), not String.starts_with?(entry, ".") do
          a = Path.join(abs, entry)
          r = if rel == "", do: entry, else: rel <> "/" <> entry

          if File.dir?(a) do
            %{name: entry, path: r, type: "folder", children: build_tree(a, r)}
          else
            %{name: entry, path: r, type: kind(entry)}
          end
        end

      _ ->
        []
    end
  end

  def kind(name) do
    if String.ends_with?(name, ".sketch.svg"), do: "sketch", else: "note"
  end

  def read(rel), do: File.read(safe!(rel))

  @doc "Save a note; if its content actually changed, file the translation request."
  def write(rel, content) do
    p = safe!(rel)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, content)
    maybe_translate(rel, content)
    :ok
  end

  @doc "Create an empty note or sketch (never overwrites)."
  def create(rel, kind) do
    p = safe!(rel)
    if File.exists?(p), do: {:error, :exists}, else: do_create(p, kind)
  end

  defp do_create(p, "folder") do
    File.mkdir_p!(p)
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
