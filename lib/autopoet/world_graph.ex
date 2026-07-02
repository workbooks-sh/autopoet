defmodule Autopoet.WorldGraph do
  @moduledoc """
  The autopoet's world as a graph — the data behind the desktop UI's force view.
  Center: the self (the face). Around it: the body's `.work` docs (with real
  backlink edges between them, from the parser's refs), the limbs, recent
  proposals (colored by verdict), and pending requests. Every node carries a
  short `detail` for the click panel. JSON here is a genuine HTTP boundary
  (same class as Nexus.Desktop's discovery file) — never config.
  """

  def payload do
    root = Nexus.Paths.data_dir()

    docs =
      Path.wildcard(Path.join(root, "**/*.work"))
      |> Enum.reject(&String.contains?(&1, "/.nexus/"))

    doc_nodes =
      for f <- docs do
        rel = Path.relative_to(f, root)
        guide? = String.contains?(rel, "guide/")

        %{
          id: "doc:#{rel}",
          label: Path.basename(rel, ".work"),
          type: if(guide?, do: "guide", else: "doc"),
          detail: f |> File.read!() |> String.slice(0, 600)
        }
      end

    by_base =
      Map.new(doc_nodes, fn n -> {n.label, n.id} end)

    ref_links =
      for f <- docs,
          rel = Path.relative_to(f, root),
          node <- safe_parse(f),
          ref <- Map.get(node, :refs, []),
          String.starts_with?(ref, "[["),
          target = ref |> String.trim_leading("[[") |> String.trim_trailing("]]"),
          dst = Map.get(by_base, target),
          dst != "doc:#{rel}",
          uniq: true do
        %{source: "doc:#{rel}", target: dst, kind: "ref"}
      end

    limb_nodes =
      for node <- Nexus.Agent.all() do
        d = safe_def(node)

        %{
          id: "limb:#{node.name}",
          label: to_string(node.name),
          type: "limb",
          detail:
            "model: #{inspect(d[:model])}\ngrant: #{inspect(d[:grant])}\nmanagement: #{Nexus.Agent.management(node)}\n\n#{String.slice(d[:system] || "", 0, 400)}"
        }
      end

    # Proposals are EPHEMERAL — a pending inbox, not durable world state. Resolved
    # ones live on disk for revert/audit but never clutter the graph (an accepted
    # proposal already IS body content; a rejected one's trace is in the capture log).
    proposal_nodes =
      for {id, status} <- Autopoet.Proposals.pending() do
        base = Path.join(Autopoet.Proposals.dir(), id)
        target = case File.read(Path.join(base, "target")) do
          {:ok, t} -> String.trim(t)
          _ -> "?"
        end

        item = case File.read(Path.join(base, "item.txt")) do
          {:ok, t} -> String.slice(t, 0, 400)
          _ -> ""
        end

        files =
          Map.keys(Autopoet.Proposals.changes(id)) ++
            Enum.map(Map.keys(Autopoet.Proposals.appends(id)), &("append → " <> &1))

        %{
          id: "prop:#{id}",
          # human-readable: what it touches + its state, not the raw hash
          label: "#{target} · #{status}",
          type: "proposal",
          status: status,
          detail: "proposal #{id}\nstatus: #{status}\nfiles: #{Enum.join(files, ", ")}\n\n#{item}"
        }
      end

    request_nodes =
      Autopoet.Requests.pending()
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        %{
          id: "req:#{i}",
          label: to_string(r.target),
          type: "request",
          detail: String.slice(to_string(r.change), 0, 500)
        }
      end)

    self_node = %{id: "self", label: "autopoet", type: "self", detail: self_detail()}

    nodes = [self_node | doc_nodes ++ limb_nodes ++ proposal_nodes ++ request_nodes]

    # everything tethers to the self unless it already hangs off another doc
    ref_targets = MapSet.new(ref_links, & &1.target)

    tethers =
      for n <- tl(nodes),
          n.type != "doc" or not MapSet.member?(ref_targets, n.id) do
        %{source: "self", target: n.id, kind: "tether"}
      end

    %{nodes: nodes, links: tethers ++ ref_links}
  end

  defp self_detail do
    st = Nexus.Autopoet.Worker.status()
    hebb = Autopoet.Shadow.Hebb.stats()
    surprise = Autopoet.Shadow.Surprise.stats()

    "heartbeat: #{if st.armed, do: "armed (#{inspect(st.spec)})", else: "disarmed"}\n" <>
      "memory: #{div(:erlang.memory(:total), 1_048_576)}MB\n" <>
      "captured events: #{Autopoet.Capture.count()}\n" <>
      "shadow: #{hebb.events} events, #{hebb.edges} pathways; surprise alarms: #{surprise.alarms}"
  end

  defp safe_parse(f) do
    Nexus.Literate.parse(File.read!(f))
  rescue
    _ -> []
  end

  defp safe_def(node) do
    Nexus.Agent.def_from_unit(node)
  rescue
    _ -> %{}
  end
end
