defmodule Autopoet.Eval.Personas do
  @moduledoc """
  The GOLDEN PERSONAS — Lane E evaluation seeds (docs/onboarding-bootstrap-plan.md §7).

  Six canned `data/profile` fixtures, one per quiz spine, each byte-faithful to what
  `quiz.js planFor/1` emits for that answer path (same workspace/agent/rule/connect/
  firstrun vocabulary — regenerate against quiz.js when the plan compiler changes).
  Every persona defines a reproducible autopoet environment: answers + notes +
  plan.* in, a whole world out — which makes the agent system benchmarkable end to
  end, and the onboarding's promises validated instead of inferred.

  `pulse/1` is the persona's synthetic world: the event stream that persona's life
  actually produces (orders landing, emails arriving, numbers moving), used by the
  live phase of the eval to verify the learning layers move on persona-shaped
  traffic.
  """

  def all, do: [shop_seller(), audience_creator(), trader(), chief_of_staff(), night_shift(), site_builder()]

  def named(name), do: Enum.find(all(), &(&1.name == name))

  # ── 1. money/sell — the bootstrap-planner exemplar (shopify seller) ─────────
  defp shop_seller do
    %{
      name: "shop-seller",
      story: "sells performance-creative services and merch; wants orders and money watched",
      workspace: "shop",
      first_agent: "shopkeeper",
      connect_head: "shopify",
      note: "i also use nix, worth knowing",
      profile: %{
        "intent" => "money",
        "money_road" => "sell",
        "industry" => "performance-creative (performance creative)",
        "speak" => "none",
        "leash" => "fenced",
        "git.notes" => "i also use nix, worth knowing",
        "plan.workspace" => "shop — orders, listings, money watch",
        "plan.agent.1" => "shopkeeper — watches orders and stock, drafts listings",
        "plan.agent.2" => "bookkeeper — reconciles payouts against orders nightly",
        "plan.rule.1" => "when an order lands, log it and update today's tally",
        "plan.rule.2" => "when an email needs a reply, draft one in my voice",
        "plan.connect" => "shopify, stripe, gmail",
        "plan.setting" => "leash=fenced pings=digest oops=revert voice=short",
        "plan.firstrun" => "the bookkeeper reconciles sample numbers onto money watch — live, on load"
      },
      pulse: [
        %{kind: "order.landed", target: "orders"},
        %{kind: "doc.touch", doc: "shop/orders.work"},
        %{kind: "doc.touch", doc: "shop/money-watch.work"},
        %{kind: "email.landed", target: "inbox"}
      ]
    }
  end

  # ── 2. money/audience — the creator ─────────────────────────────────────────
  defp audience_creator do
    %{
      name: "audience-creator",
      story: "builds an audience around short video essays; calendar must never go empty",
      workspace: "studio",
      first_agent: "producer",
      connect_head: "instagram",
      note: "my voice is dry, never chirpy — read three posts before drafting",
      profile: %{
        "intent" => "money",
        "money_road" => "audience",
        "industry" => "video-essays (video essays)",
        "speak" => "none",
        "leash" => "fenced",
        "voice.notes" => "my voice is dry, never chirpy — read three posts before drafting",
        "aspirations" => "publish,ghost",
        "plan.workspace" => "studio — content, calendar, audience watch",
        "plan.agent.1" => "producer — drafts posts in your voice, keeps the calendar full",
        "plan.rule.1" => "every week, draft the next post in my voice",
        "plan.rule.2" => "learn my voice from everything i write",
        "plan.connect" => "instagram, gmail",
        "plan.setting" => "leash=fenced pings=weekly oops=revert voice=long",
        "plan.firstrun" => "the bookkeeper reconciles sample numbers onto money watch — live, on load"
      },
      pulse: [
        %{kind: "post.due", target: "calendar"},
        %{kind: "doc.touch", doc: "studio/content.work"},
        %{kind: "doc.touch", doc: "studio/calendar.work"},
        %{kind: "comment.landed", target: "audience watch"}
      ]
    }
  end

  # ── 3. money/trade — the trader ──────────────────────────────────────────────
  defp trader do
    %{
      name: "trader",
      story: "swing-trades a small book; wants one alert per real move, no noise",
      workspace: "terminal",
      first_agent: "lookout",
      connect_head: "tradingview",
      note: "alert me once per move — repeated pings train me to ignore you",
      profile: %{
        "intent" => "money",
        "money_road" => "trade",
        "industry" => "prop-trading (prop trading)",
        "speak" => "little",
        "leash" => "tight",
        "alerts.notes" => "alert me once per move — repeated pings train me to ignore you",
        "plan.workspace" => "terminal — watchlist, alerts, journal",
        "plan.agent.1" => "lookout — watches your list, alerts on real moves",
        "plan.rule.1" => "when a watched number moves hard, alert me once",
        "plan.connect" => "tradingview",
        "plan.setting" => "leash=tight pings=live oops=ask voice=short",
        "plan.firstrun" => "the bookkeeper reconciles sample numbers onto money watch — live, on load"
      },
      pulse: [
        %{kind: "price.move", target: "watchlist"},
        %{kind: "doc.touch", doc: "terminal/watchlist.work"},
        %{kind: "doc.touch", doc: "terminal/journal.work"},
        %{kind: "price.move", target: "watchlist"}
      ]
    }
  end

  # ── 4. productivity — the drowning operator ─────────────────────────────────
  defp chief_of_staff do
    %{
      name: "chief-of-staff",
      story: "runs a small agency from an inbox that never empties; wants mornings back",
      workspace: "desk",
      first_agent: "chief_of_staff",
      connect_head: "gmail",
      note: "clients expect replies same day — flag anything older than 20 hours",
      profile: %{
        "intent" => "productivity",
        "prod_pain" => "inbox",
        "industry" => "design-agency (design agency)",
        "speak" => "none",
        "leash" => "fenced",
        "inbox.notes" => "clients expect replies same day — flag anything older than 20 hours",
        "plan.workspace" => "desk — inbox watch, today, paper trail",
        "plan.agent.1" => "chief of staff — triages your inbox, drafts replies, keeps today current",
        "plan.rule.1" => "when an email needs a reply, draft one in my voice",
        "plan.connect" => "gmail, google drive",
        "plan.setting" => "leash=fenced pings=digest oops=revert voice=short",
        "plan.firstrun" => "the chief of staff triages your last 24 hours of inbox on load"
      },
      pulse: [
        %{kind: "email.landed", target: "inbox watch"},
        %{kind: "doc.touch", doc: "desk/inbox-watch.work"},
        %{kind: "doc.touch", doc: "desk/today.work"},
        %{kind: "email.landed", target: "inbox watch"}
      ]
    }
  end

  # ── 5. delegate — the night-shift researcher fleet ──────────────────────────
  defp night_shift do
    %{
      name: "night-shift",
      story: "hands the overnight research queue to a fleet; reads the report at breakfast",
      workspace: "night-shift",
      first_agent: "night_researcher",
      connect_head: "github",
      note: "cite sources in every report — an uncited claim is a deleted claim",
      profile: %{
        "intent" => "delegate",
        "delegate_job" => "research",
        "hours" => "nights",
        "burn" => "steady",
        "industry" => "market-research (market research)",
        "speak" => "fluent",
        "leash" => "loose",
        "queue.notes" => "cite sources in every report — an uncited claim is a deleted claim",
        "plan.workspace" => "night shift — queue, morning report, fleet log",
        "plan.agent.1" => "night researcher — digs into the queue, reports by morning",
        "plan.agent.2" => "foreman — watches budget and hours, kills overruns",
        "plan.rule.1" => "every night, take the top question and report by morning",
        "plan.connect" => "github, google",
        "plan.setting" => "leash=loose pings=digest oops=log voice=long",
        "plan.fleet" => "hours=nights budget=steady",
        "plan.firstrun" => "the fleet takes its first job the moment the world opens"
      },
      pulse: [
        %{kind: "queue.item", target: "queue"},
        %{kind: "doc.touch", doc: "night-shift/queue.work"},
        %{kind: "doc.touch", doc: "night-shift/morning-report.work"},
        %{kind: "limb.returned", target: "night_researcher"}
      ]
    }
  end

  # ── 6. build/site — the taste-driven site builder ───────────────────────────
  defp site_builder do
    %{
      name: "site-builder",
      story: "grows a personal studio site; every page must match an exacting taste",
      workspace: "site-studio",
      first_agent: "art_director",
      connect_head: "cloudflare",
      note: "no stock imagery ever — placeholder art is worse than blank space",
      profile: %{
        "intent" => "build",
        "build_what" => "site",
        "industry" => "editorial-design (editorial design)",
        "speak" => "little",
        "leash" => "fenced",
        "taste.notes" => "no stock imagery ever — placeholder art is worse than blank space",
        "plan.workspace" => "site studio — site, design tokens, publish log",
        "plan.agent.1" => "art director — keeps everything matching your taste",
        "plan.rule.1" => "when i add a page, style it to my taste and stage a preview",
        "plan.connect" => "cloudflare, github",
        "plan.setting" => "leash=fenced pings=digest oops=revert voice=short",
        "plan.firstrun" => "a starter build blooms from your answers on load"
      },
      pulse: [
        %{kind: "page.added", target: "site"},
        %{kind: "doc.touch", doc: "site-studio/site.work"},
        %{kind: "doc.touch", doc: "site-studio/design-tokens.work"},
        %{kind: "page.added", target: "site"}
      ]
    }
  end
end
