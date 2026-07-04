defmodule Autopoet.WorkspaceEvalTest do
  @moduledoc """
  Workspace toolkit eval (v3, wb-siutv) — Google Workspace + GitHub sync, the
  everyday integrations the agent works with. Injected transports (no live
  calls, no tokens; identical code runs live on a connected account):

    W-GMAIL   list + read messages; a DRAFT is created (safe); SEND is GATED.
    W-CAL     list events (safe); create is GATED.
    W-SHEET   read a range (safe).
    W-GH      read a repo file (safe); COMMIT (the sync lane) is GATED.
    W-GATE    every outward action refuses without opts[:confirm], and fires
              with it — the cage extends to the outside world.
  """
  use ExUnit.Case, async: false

  alias Autopoet.Workspace, as: WS

  # a transport that records the calls and returns Google/GitHub-shaped fixtures
  defp transport(sink) do
    fn method, url, body ->
      :ets.insert(sink, {System.unique_integer([:monotonic]), method, url, body})

      cond do
        String.contains?(url, "/messages?q=") -> {:ok, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]}}
        String.contains?(url, "/messages/m1") -> {:ok, %{"id" => "m1", "snippet" => "invoice due friday"}}
        String.contains?(url, "/drafts") -> {:ok, %{"id" => "draft_1"}}
        String.contains?(url, "/messages/send") -> {:ok, %{"id" => "sent_1"}}
        String.contains?(url, "/events?") -> {:ok, %{"items" => [%{"summary" => "standup", "start" => %{"dateTime" => "2026-07-06T09:00:00Z"}}]}}
        method == :post and String.contains?(url, "/events") -> {:ok, %{"id" => "ev_1", "status" => "confirmed"}}
        String.contains?(url, "/values/") -> {:ok, %{"values" => [["Q3", "42000"], ["Q4", "51000"]]}}
        String.contains?(url, "/contents/README") -> {:ok, %{"content" => Base.encode64("# The Repo")}}
        method == :put and String.contains?(url, "/contents/") -> {:ok, %{"commit" => %{"sha" => "abc123"}}}
        true -> {:ok, %{}}
      end
    end
  end

  setup do
    sink = :ets.new(:ws_calls, [:public, :ordered_set])
    {:ok, sink: sink, t: transport(sink)}
  end

  test "W-GMAIL: list + read + draft (safe); send is gated", %{t: t} do
    assert {:ok, %{"messages" => msgs}} = WS.gmail_list("is:unread", transport: t)
    assert length(msgs) == 2
    assert {:ok, %{"snippet" => snip}} = WS.gmail_read("m1", transport: t)
    assert snip =~ "invoice"

    # a DRAFT is safe — created without confirmation
    assert {:ok, %{"id" => "draft_1"}} = WS.gmail_draft(%{to: "a@b.co", subject: "re: invoice", body: "on it"}, transport: t)

    # SEND is gated
    assert {:gated, :needs_confirmation} = WS.gmail_send(%{to: "a@b.co", subject: "x", body: "y"}, transport: t)
    assert {:ok, %{"id" => "sent_1"}} = WS.gmail_send(%{to: "a@b.co", subject: "x", body: "y"}, transport: t, confirm: true)

    IO.puts("  ✓ EVAL workspace/gmail — list #{length(msgs)}, read, draft (safe); send gated then confirmed")
  end

  test "W-CAL: list events (safe); create gated", %{t: t} do
    assert {:ok, %{"items" => evs}} = WS.calendar_list(transport: t)
    assert hd(evs)["summary"] == "standup"

    assert {:gated, _} = WS.calendar_create(%{summary: "review", start_iso: "2026-07-07T10:00:00Z", end_iso: "2026-07-07T10:30:00Z"}, transport: t)
    assert {:ok, %{"status" => "confirmed"}} = WS.calendar_create(%{summary: "review", start_iso: "2026-07-07T10:00:00Z", end_iso: "2026-07-07T10:30:00Z"}, transport: t, confirm: true)

    IO.puts("  ✓ EVAL workspace/calendar — list events (safe); create gated then confirmed")
  end

  test "W-SHEET: read a range (safe)", %{t: t} do
    assert {:ok, %{"values" => rows}} = WS.sheet_read("sheet_abc", "A1:B2", transport: t)
    assert rows == [["Q3", "42000"], ["Q4", "51000"]]
    IO.puts("  ✓ EVAL workspace/sheets — read #{length(rows)} rows")
  end

  test "W-GH: read a file (safe); commit (the sync lane) is gated", %{t: t} do
    assert {:ok, content} = WS.github_read("acme/widget", "README.md", transport: t)
    assert content == "# The Repo"

    # the SYNC — pushing the agent's work — is gated
    assert {:gated, _} = WS.github_commit("acme/widget", "notes/today.md", "todays work", "sync: today", transport: t)
    assert {:ok, %{"commit" => %{"sha" => "abc123"}}} =
             WS.github_commit("acme/widget", "notes/today.md", "todays work", "sync: today", transport: t, confirm: true, sha: "old")

    IO.puts("  ✓ EVAL workspace/github — read file (safe); commit/sync gated then confirmed")
  end

  test "W-GATE: unconnected + unconfirmed both refuse cleanly (never crash)" do
    # no transport, no token → skip (not a crash)
    assert {:skip, :not_connected} = WS.gmail_list("x", token: nil)
    # gated action without confirm → gated, regardless of transport
    assert {:gated, :needs_confirmation} = WS.github_commit("a/b", "f", "c", "m", transport: fn _, _, _ -> {:ok, %{}} end)
    IO.puts("  ✓ EVAL workspace/gate — unconnected skips, outward actions gated by default")
  end
end
