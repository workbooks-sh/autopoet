defmodule Autopoet.LanesEvalTest do
  @moduledoc """
  The full-plan lanes (lifecycle-plan §2/§4) — self-serve identity, domain
  purchase (Treasury-gated), Shopify. Injected transports; production code.
  """
  use ExUnit.Case, async: false

  test "SELF-SERVE: inbox verify loop closes itself; bot-wall → needs-human; empty → no_mail" do
    msgs = [%{"subject" => "Verify your Plausible email", "text" => "Click https://plausible.io/confirm?token=abc to verify."}]

    # link found + confirm 2xx → verified (the CiteFlows/CF mechanic, generalized)
    assert {:verified, "https://plausible.io/confirm?token=abc"} =
             Autopoet.SelfServe.await_verification("x@agentmail.to", ~r/Verify/,
               mail: fn _ -> msgs end, confirm: fn _ -> :ok end)

    # bot-wall → the exact link comes back as a needs-human card, no thrash
    assert {:needs_human, _} =
             Autopoet.SelfServe.await_verification("x@agentmail.to", ~r/Verify/,
               mail: fn _ -> msgs end, confirm: fn _ -> :blocked end)

    # nothing arrives in the window → honest no_mail (short wait)
    assert {:no_mail, nil} =
             Autopoet.SelfServe.await_verification("x@agentmail.to", ~r/Verify/,
               mail: fn _ -> [] end, confirm: fn _ -> :ok end, wait_ms: 200, poll_ms: 50)

    IO.puts("  ✓ EVAL lanes/self-serve — verify loop closes; bot-wall→needs-human; empty→no_mail")
  end

  test "REGISTRAR: buy charges the Treasury FIRST — unfunded refuses the registration" do
    Autopoet.Treasury.reset()
    calls = :ets.new(:reg, [:public])

    t = fn path, _extra -> :ets.insert(calls, {path}) && {:ok, %{"status" => "SUCCESS"}} end

    # unfunded treasury (cap 0) → refused BEFORE any registrar call
    assert {:error, {:treasury_refused, _}} = Autopoet.Registrar.buy("example.com", price: 11.0, transport: t)
    assert :ets.info(calls, :size) == 0, "registrar was called despite refused spend"

    # human funds + revenue → buy proceeds, registrar called once
    Autopoet.Treasury.fund(50.0, 50.0)
    Autopoet.Treasury.earn(20.0, :test)
    assert {:ok, %{"status" => "SUCCESS"}} = Autopoet.Registrar.buy("example.com", price: 11.0, transport: t)
    assert :ets.info(calls, :size) == 1
    Autopoet.Treasury.reset()

    IO.puts("  ✓ EVAL lanes/registrar — Treasury gates the money verb; unfunded blocks the buy")
  end

  test "SHOPIFY: reads safe, probe works, unconfigured skips clean" do
    t = fn
      :get, "/shop.json", _ -> {:ok, %{"shop" => %{"name" => "Test Store", "domain" => "test.myshopify.com"}}}
      :get, "/products.json" <> _, _ -> {:ok, %{"products" => [%{"id" => 1, "title" => "Widget"}]}}
      :post, "/products.json", body -> {:ok, %{"product" => Map.put(body["product"], "id", 2)}}
    end

    assert {:ok, %{"shop" => %{"name" => "Test Store"}}} = Autopoet.Shopify.shop(transport: t)
    assert {:ok, %{"products" => [_]}} = Autopoet.Shopify.products(transport: t)
    assert {:ok, %{"product" => %{"id" => 2}}} = Autopoet.Shopify.create_product(%{"title" => "New"}, transport: t)
    # no store/token, no transport → clean skip (never a crash)
    assert {:skip, :not_configured} = Autopoet.Shopify.shop([])

    IO.puts("  ✓ EVAL lanes/shopify — probe + reads + gated write via transport; unconfigured skips")
  end

  test "FEATURED SIX: connection order promotes AgentMail, drops OpenRouter from the front" do
    featured = Enum.take(Autopoet.Connections.providers(), 6)
    assert "agentmail" in featured
    refute "openrouter" in featured
    IO.puts("  ✓ EVAL lanes/featured — #{inspect(featured)}")
  end
end
