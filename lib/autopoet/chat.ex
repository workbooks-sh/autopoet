defmodule Autopoet.Chat do
  @moduledoc """
  Talking WITH the autopoet — a conversational lane beside the vault (notes are
  still the source of truth; chat is how you think out loud with it).

  Sessions are plain-text transcripts in `data/chats/<id>.chat`:

      === chat <id> · <date> ===
      [user] ...
      [autopoet] ...

  Replies run through the planner model (OpenRouter, same money boundary as the
  brain) with a world snapshot as context. Chat NEVER edits anything — if the
  human asks for changes, the reply points them at the vault (notes → translation
  → gated proposals), keeping the containment story intact.

  Test seam: `:chat_llm` (`fn messages -> {:ok, text} end`).
  """

  def dir, do: Path.join([Autopoet.Discovery.home(), "data", "chats"])
  defp path(id), do: Path.join(dir(), safe_id!(id) <> ".chat")

  def new do
    File.mkdir_p!(dir())

    id =
      "c#{System.os_time(:second)}-#{:erlang.unique_integer([:positive])}"

    File.write!(path(id), "=== chat #{id} · #{Date.utc_today()} ===\n")
    id
  end

  def sessions do
    File.mkdir_p!(dir())

    dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".chat"))
    |> Enum.sort(:desc)
    |> Enum.map(fn f ->
      id = String.trim_trailing(f, ".chat")
      body = File.read!(Path.join(dir(), f))

      preview =
        body
        |> String.split("\n")
        |> Enum.find_value("", fn
          "[user] " <> rest -> String.slice(rest, 0, 80)
          _ -> nil
        end)

      %{id: id, preview: preview}
    end)
  end

  def transcript(id), do: File.read(path(id))

  @doc "Append the human's message, complete a reply in context, append + return it."
  def send(id, msg) when is_binary(msg) do
    p = path(id)
    unless File.exists?(p), do: File.write!(p, "=== chat #{id} · #{Date.utc_today()} ===\n")

    File.write!(p, File.read!(p) <> "[user] #{single_block(msg)}\n", [:sync])

    case complete(messages_for(p)) do
      {:ok, reply} ->
        File.write!(p, File.read!(p) <> "[autopoet] #{single_block(reply)}\n", [:sync])
        {:ok, reply}

      other ->
        other
    end
  end

  # transcript lines → chat messages (last 24 turns), system prompt first
  defp messages_for(p) do
    turns =
      File.read!(p)
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "[user] " <> t -> [%{role: "user", content: unblock(t)}]
        "[autopoet] " <> t -> [%{role: "assistant", content: unblock(t)}]
        _ -> []
      end)
      |> Enum.take(-24)

    [%{role: "system", content: system_prompt()} | turns]
  end

  defp system_prompt do
    pending = length(Autopoet.Proposals.pending())

    vault =
      Autopoet.Notes.tree()
      |> flatten_tree()
      |> Enum.take(40)
      |> Enum.join(", ")

    log = Autopoet.Log.recent(8) |> Enum.join("\n")

    """
    You are the autopoet — a self-authoring workbook organism living in a desktop
    shell. You converse; you NEVER edit anything from chat. All change flows one
    way: the human writes notes in the vault (source of truth) → your brain
    translates them into .work proposals → the human gates them. If asked to
    change something, say what note to write, or note it will surface as a
    proposal on your next heartbeat.

    Today: <#{Date.utc_today()}>. Pending proposals: #{pending}.
    Vault: #{vault}
    Recent activity:
    #{log}

    Be concise and concrete. Reference pages as [[name]].
    """
  end

  defp flatten_tree(items, prefix \\ "") do
    Enum.flat_map(items, fn
      %{type: "folder", name: n, children: c} -> flatten_tree(c, prefix <> n <> "/")
      %{name: n} -> [prefix <> n]
    end)
  end

  defp complete(messages) do
    cond do
      fun = Application.get_env(:autopoet, :chat_llm) -> fun.(messages)
      Autopoet.Providers.openrouter?() -> Autopoet.Providers.openrouter(messages)
      true -> {:error, :no_provider}
    end
  end

  # transcripts are line-oriented: newlines inside a turn ride as ⏎
  defp single_block(t), do: t |> String.trim() |> String.replace("\n", " ⏎ ")
  defp unblock(t), do: String.replace(t, " ⏎ ", "\n")

  defp safe_id!(id) do
    id = to_string(id)

    if id =~ ~r/^[A-Za-z0-9_-]+$/ do
      id
    else
      raise ArgumentError, "unsafe chat id"
    end
  end
end
