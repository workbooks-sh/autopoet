defmodule Autopoet.ActionsEvalTest do
  @moduledoc """
  Action vocabulary eval (wb-siutv.2) — the brain can DO, not just author.
  Native lanes + Composio's connected catalog, unified, with the cage applied
  to every tool. Injected transports throughout (no live calls).

    A-VOCAB    the vocabulary merges native lanes + connected Composio tools.
    A-SAFE     a safe action (a read) performs and settles action.performed.
    A-GATED    a gated action (send/commit/trade) does NOT fire — it becomes a
               pending proposal (the human gate).
    A-COMPOSIO Composio tools appear with safety inferred from the verb;
               a write-verb tool is gated, a read-verb tool is safe.
    A-INTENTS  brain-style `=== action: … ===` blocks parse + route correctly.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Actions

  # an injected Composio source: two tools, one read (safe), one write (gated)
  defp composio_src do
    fn ->
      [
        %{"slug" => "NOTION_GET_PAGE", "description" => "Read a Notion page", "function" => %{"parameters" => %{}}},
        %{"slug" => "SLACK_SEND_MESSAGE", "description" => "Send a Slack message", "function" => %{"parameters" => %{}}}
      ]
    end
  end

  test "A-VOCAB: vocabulary merges native lanes + connected Composio tools" do
    vocab = Actions.vocabulary(composio_source: composio_src())
    names = Enum.map(vocab, & &1.name)

    # native lanes present
    assert "alpaca_bars" in names and "gmail_draft" in names and "github_commit" in names
    # composio tools folded in
    assert "NOTION_GET_PAGE" in names and "SLACK_SEND_MESSAGE" in names

    native = Enum.filter(vocab, &(&1.source == :native))
    composio = Enum.filter(vocab, &(&1.source == :composio))
    assert length(native) >= 10 and length(composio) == 2

    IO.puts("  ✓ EVAL actions/vocab — #{length(native)} native + #{length(composio)} composio tools in one vocabulary")
  end

  test "A-SAFE: a safe action performs through its injected lane + settles" do
    Nexus.Events.subscribe()
    t = fn :get, url, _b -> if String.contains?(url, "/bars"), do: {:ok, %{"bars" => [%{"c" => 101.0}]}}, else: {:ok, %{}} end

    assert {:ok, %{"bars" => bars}} = Actions.invoke("alpaca_bars", %{"symbol" => "AAPL"}, transport: t)
    assert length(bars) == 1
    assert_receive {:event, %{kind: "action.performed", action: "alpaca_bars", status: :ok}}, 1_000

    IO.puts("  ✓ EVAL actions/safe — alpaca_bars performed via injected lane, settled action.performed")
  end

  test "A-GATED: a gated action is proposed, never fired" do
    # a gated action WITHOUT confirm → does not run, becomes a proposal
    assert {:proposed, id} = Actions.route("gmail_send", %{"to" => "a@b.co", "subject" => "hi", "body" => "x"})
    assert is_binary(id)

    # the proposal is pending for the human, targeting the action
    assert Enum.any?(Autopoet.Proposals.pending(), fn {pid, _} ->
             Autopoet.Proposals.target_of(pid) == "action:gmail_send"
           end)

    Autopoet.Proposals.reject(id, "eval cleanup")
    IO.puts("  ✓ EVAL actions/gated — gmail_send held as a proposal, not sent")
  end

  test "A-COMPOSIO: Composio tool safety inferred from the verb" do
    read = Actions.find("NOTION_GET_PAGE", composio_source: composio_src())
    write = Actions.find("SLACK_SEND_MESSAGE", composio_source: composio_src())
    assert read.safety == :safe
    assert write.safety == :gated
    IO.puts("  ✓ EVAL actions/composio — NOTION_GET_PAGE safe, SLACK_SEND_MESSAGE gated (verb-inferred)")
  end

  test "A-INTENTS: brain-style action blocks parse + route (safe performs, gated proposes)" do
    t = fn :get, _url, _b -> {:ok, %{"messages" => [%{"id" => "m1"}]}} end

    text = """
    Here's my plan.

    === action: gmail_list ===
    {"query": "is:unread"}

    === action: github_commit ===
    {"repo": "acme/w", "path": "notes.md", "content": "hi", "message": "sync"}
    """

    routed = Actions.route_intents(text, transport: t)
    assert length(routed) == 2

    {_, gmail_result} = Enum.find(routed, fn {n, _} -> n == "gmail_list" end)
    assert {:performed, {:ok, %{"messages" => _}}} = gmail_result

    {_, commit_result} = Enum.find(routed, fn {n, _} -> n == "github_commit" end)
    assert {:proposed, cid} = commit_result
    Autopoet.Proposals.reject(cid, "eval cleanup")

    IO.puts("  ✓ EVAL actions/intents — 2 intents parsed: gmail_list performed, github_commit proposed")
  end
end
