defmodule Autopoet.PipelineEvalTest do
  @moduledoc """
  THE FULL LIFECYCLE PIPELINE (lifecycle-plan, goal-set) — proven end to end
  through PRODUCTION machinery, hermetically:

    ctl HTTP (Control plug) → project born conversationally → desk (spine) →
    genesis 1-3 (scripted brain; web research skipped via empty harvest) →
    CHARTER proposal with the TYPED INTEGRATION CHECKLIST → digest groups it →
    ctl accept → charter in the project's vault → chartered loop → identity →
    logo → BUILD → deploy (seam) → site html with live waitlist action.

  Fast: tick 150ms, slot 1s. No network, no LLM (scripted), no wrangler (seam).
  """
  use ExUnit.Case, async: false
  use Plug.Test

  # salted: archive keeps the VAULT charter (constitutions stay readable), so a
  # reused slug would skip genesis on re-runs — the shared-home lesson again
  setup do
    slug = "pipeline-eval-#{System.os_time(:millisecond)}"
    Process.put(:pipeline_slug, slug)

    Application.put_env(:autopoet, :desk_tick_ms, 150)
    Application.put_env(:autopoet, :desk_slot_s, 1)
    Application.put_env(:autopoet, :venture_deploy, fn _dir -> {:ok, "https://pipeline-eval.example"} end)
    Application.put_env(:autopoet, :brain_llm, &scripted_brain/1)
    Application.put_env(:autopoet, :venture_search, fn _q -> {:ok, []} end)

    on_exit(fn ->
      Autopoet.Desks.halt(slug)
      Application.delete_env(:autopoet, :desk_tick_ms)
      Application.delete_env(:autopoet, :desk_slot_s)
      Application.delete_env(:autopoet, :venture_deploy)
      Application.delete_env(:autopoet, :brain_llm)
      Application.delete_env(:autopoet, :venture_search)
    end)

    {:ok, slug: slug}
  end

  defp scripted_brain(prompt) do
    cond do
      prompt =~ "3 focused search queries" ->
        {:ok, "pipeline eval query"}

      prompt =~ "BOOTSTRAPPING YOUR OWN SaaS VENTURE" ->
        {:ok, "## Pain\nAgencies drown in manual reports (source: onboarding note)."}

      prompt =~ "COMMIT: pick ONE niche" ->
        {:ok, "## Thesis\nNiche: agency reporting. Product: one-click AI report."}

      prompt =~ "FOUNDING CHARTER" ->
        {:ok,
         """
         ## Mission
         Prove one-click AI reporting for agencies.
         ## Niche
         Boutique agencies, 5-30 seats.
         ## Product
         ReportBot — one workflow: connect, click, report.
         ## Validation
         50 verified signups in 14 days or kill.
         ## GTM
         Honest practitioner content on X and communities.
         ## Metrics
         Signups weekly; qualitative replies.
         ## Kill criteria
         Fewer than 50 signups by day 14 → stop.
         ## Integrations
         - [connected] cloudflare — deploy the landing page
         - [self-serve] plausible — analytics, I sign up with my own inbox
         - [needs-human] x-dev-account — posting needs owner-paid API
         - [suggested] shopify — if commerce emerges
         """}

      prompt =~ "Claim your venture's IDENTITY" ->
        {:ok, "## Domain\nreportbot.example (owned zone)\n## Email\n- beta@reportbot.example\n## X presence\nHandle: @zaiusai rebrand\n## Site\nhttps://reportbot.example"}

      prompt =~ "design YOUR OWN LOGO" ->
        {:ok,
         """
         Concept one line.
         === svg: concept1-icon ===
         <svg viewBox="0 0 24 24" role="img"><title>r</title><desc>mark</desc><circle cx="12" cy="12" r="9"/></svg>
         === svg: primary-mono ===
         <svg viewBox="0 0 24 24" role="img"><title>r</title><desc>mono</desc><circle cx="12" cy="12" r="9"/></svg>
         PRIMARY: concept1
         """}

      prompt =~ "building session" ->
        {:ok,
         """
         === html ===
         <!doctype html><html><head><title>ReportBot</title><meta name="description" content="one-click reports"><script type="application/ld+json">{"@type":"SoftwareApplication"}</script></head><body><form action="/api/waitlist" method="POST"><input type="email" name="email"></form></body></html>
         """}

      true ->
        {:ok, "hold — nothing to do this slot."}
    end
  end

  defp ctl(method, path, body \\ nil) do
    conn =
      conn(method, path, body)
      |> put_req_header("authorization", "Bearer " <> Autopoet.Discovery.token())

    Autopoet.Control.call(conn, Autopoet.Control.init([]))
  end

  defp await(fun, ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      case fun.() do
        nil -> Process.sleep(100) && nil
        false -> Process.sleep(100) && nil
        v -> v
      end
    end)
    |> Enum.find(fn v ->
      v || System.monotonic_time(:millisecond) > deadline
    end)
  end

  test "PIPELINE: ctl → genesis → chartered checklist → digest → accept → identity → logo → build → deploy", %{slug: slug} do
    # 1 · conversational creation over the SAME HTTP surface the packaged app exposes
    resp = ctl(:post, "/projects/new?slug=#{slug}&archetype=venture", "Build a reporting SaaS for agencies. Prove demand honestly.")
    assert resp.status == 200 and resp.resp_body =~ "desk running"

    # onboarding note landed; project listed over ctl
    assert File.read!(Path.join(Autopoet.Projects.artifacts_dir(slug), "onboarding.txt")) =~ "reporting SaaS"
    assert ctl(:get, "/projects").resp_body =~ slug

    # 2 · genesis runs to the charter proposal (3 slots ≈ 3s at test speed)
    assert await(fn ->
             Enum.find(Autopoet.Proposals.pending(), fn {id, _} ->
               Autopoet.Proposals.target_of(id) == "projects/#{slug}/charter.work"
             end)
           end, 20_000), "charter proposal never landed"

    {charter_id, _} =
      Enum.find(Autopoet.Proposals.pending(), fn {id, _} ->
        Autopoet.Proposals.target_of(id) == "projects/#{slug}/charter.work"
      end)

    # the TYPED INTEGRATION CHECKLIST is in the draft
    draft = Autopoet.Proposals.changes(charter_id) |> Map.new() |> Map.fetch!("projects/#{slug}/charter.work")
    for tag <- ~w([connected] [self-serve] [needs-human] [suggested]) do
      assert draft =~ tag, "checklist missing #{tag}"
    end

    # 3 · the digest groups it under the project
    digest = ctl(:get, "/digest").resp_body
    assert digest =~ slug and digest =~ charter_id

    # 4 · accept over ctl → charter lands in the project's VAULT
    assert ctl(:post, "/proposal/#{charter_id}/accept").resp_body =~ "accepted"
    assert File.exists?(Autopoet.Projects.charter_path(slug))
    Autopoet.Projects.mark_chartered(slug)

    # 5 · chartered loop: identity proposal → accept → logo → build → deploy
    assert await(fn ->
             Enum.find(Autopoet.Proposals.pending(), fn {id, _} ->
               Autopoet.Proposals.target_of(id) == "projects/#{slug}/identity.work"
             end)
           end, 20_000), "identity proposal never landed"

    {id2, _} =
      Enum.find(Autopoet.Proposals.pending(), fn {id, _} ->
        Autopoet.Proposals.target_of(id) == "projects/#{slug}/identity.work"
      end)

    assert ctl(:post, "/proposal/#{id2}/accept").resp_body =~ "accepted"

    # logo assets then the built site (deploy seam records the URL in status)
    assert await(fn -> File.exists?(Path.join(Autopoet.Projects.artifacts_dir(slug), "site/assets/primary-mono.svg")) end, 20_000), "logo never landed"
    assert await(fn -> File.exists?(Path.join(Autopoet.Projects.artifacts_dir(slug), "site/index.html")) end, 20_000), "site never built"

    html = File.read!(Path.join(Autopoet.Projects.artifacts_dir(slug), "site/index.html"))
    assert html =~ ~s(action="/api/waitlist") and html =~ "ld+json"

    assert await(fn -> Autopoet.Venture.status(slug).site_url == "https://pipeline-eval.example" end, 10_000), "deploy seam url never recorded"

    # 6 · ctl status + archive close the lifecycle
    assert ctl(:get, "/projects/#{slug}/status").resp_body =~ "chartered=true"
    assert ctl(:post, "/projects/#{slug}/archive").resp_body =~ "archived"
    refute Autopoet.Desks.running?(slug)

    IO.puts("  ✓ EVAL pipeline — ctl→genesis→typed checklist→digest→accept→identity→logo→build→deploy→archive, all production machinery")
  end
end
