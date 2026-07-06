# The "BEFORE" scorecard — the training-readiness of the corpus we already have,
# captured BEFORE the decision-context schema enrichment. Re-run after evals run
# with the enriched schema to see the delta (feature-completeness should climb
# from ~0 toward 1.0 as new, context-carrying decisions accumulate).
#
#   Run: cd autopoet && TRACE_ROOT=$(pwd)/_build/test_home mix run --no-start spike/baseline.exs

dir = Autopoet.Shadow.Trace.dir(System.get_env("TRACE_ROOT"))
ev = Autopoet.Shadow.Trace.events(dir)
IO.puts("\n######## corpus baseline (BEFORE schema enrichment) ########")
IO.puts("trace dir: #{dir}\ntotal events: #{length(ev)}")

# ── labeled-dataset scorecard (the linker) ──
triples = Autopoet.Shadow.Trace.triples(ev)
s = Autopoet.Shadow.Trace.label_stats(triples)
IO.puts("\n── labeled decisions (decision → verdict → market reward) ──")
IO.puts("  decisions recorded : #{s.decisions}")
IO.puts("  proxy-labeled      : #{s.proxy_labeled}   (verdicts: #{inspect(s.verdicts)})")
IO.puts("  market-labeled      : #{s.market_labeled}   (a real reward landed on the target)")
fc_pct = if s.decisions > 0, do: Float.round(s.feature_complete / s.decisions * 100, 1), else: 0.0
IO.puts("  FEATURE-COMPLETE    : #{s.feature_complete}/#{s.decisions} = #{fc_pct}%   <- the schema-fix lever")

# ── data-quality gate (kind lens) ──
sig = Autopoet.Shadow.Trace.signals(ev, :kind)
if length(sig) >= 50 do
  g = Autopoet.Shadow.Trace.order_gate(sig)
  b1 = g[1].bits && Float.round(g[1].bits, 3)
  best = 2..3 |> Enum.map(&(g[&1].bits)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
  IO.puts("\n── data quality (kind lens, #{length(sig)} signals) ──")
  IO.puts("  first-order bits/event : #{b1}")
  IO.puts("  best higher-order bits  : #{best && Float.round(best, 3)}   verdict: #{g.verdict}")
end

IO.puts("\n=> BEFORE mark set. The number that matters is FEATURE-COMPLETE %: it is")
IO.puts("   the fraction of decisions that carry the context needed to train on.")
IO.puts("   Pre-enrichment it is ~0 (labels without features); every eval run AFTER")
IO.puts("   the schema fix lands feature-complete rows and pulls this toward 100%.")
