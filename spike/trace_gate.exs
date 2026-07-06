# Run the higher-order gate over the REAL captured event corpus (whatever
# `Autopoet.Capture` has recorded to data/traces so far). Re-run this anytime —
# the more the dev server / agent runs, the bigger the corpus and the sharper the
# verdict. This is the real-data version of spike/higher_order_signal.exs.
#
#   Run: cd autopoet && mix run --no-start spike/trace_gate.exs
#   (optional) TRACE_ROOT=/path/to/home  to point at a different home

root = System.get_env("TRACE_ROOT")
dir = Autopoet.Shadow.Trace.dir(root)
IO.puts("\n#### higher-order gate on REAL captured traces ####")
IO.puts("trace dir: #{dir}")

events = Autopoet.Shadow.Trace.events(dir)
IO.puts("captured events=#{length(events)}")

run_lens = fn level ->
  signals = Autopoet.Shadow.Trace.signals(events, level)
  stats = Autopoet.Shadow.Trace.stats(signals)
  IO.puts("\n── lens: #{level}  (signals=#{stats.n}  vocab=#{stats.vocab}) ──")
  IO.puts("top: " <> (stats.top |> Enum.map_join(", ", fn {s, c} -> "#{s}×#{c}" end)))

  if stats.n < 50 do
    IO.puts("(only #{stats.n} signals — grow the corpus; pipeline is wired and ready)")
  else
    g = Autopoet.Shadow.Trace.order_gate(signals)
    IO.puts("  k | bits/event (seen ctx) | coverage")
    for k <- 1..3 do
      r = g[k]
      b = if r.bits, do: :erlang.float_to_binary(r.bits, decimals: 3), else: "n/a"
      :io.format("  ~w | ~-21s | ~s~n", [k, b, :erlang.float_to_binary(r.coverage, decimals: 2)])
    end

    msg =
      case g.verdict do
        :higher_order_signal_present -> "HIGHER-ORDER SIGNAL PRESENT — history lowers bits; a learned minGRU is justified."
        :first_order_sufficient -> "first-order sufficient — extra history doesn't help on this corpus."
        :need_more_traces -> "need more traces — 2-back contexts too sparse (low coverage)."
        :insufficient_data -> "insufficient data."
      end

    IO.puts("  => #{msg}")
  end
end

IO.puts("\n#### verdict runs on TWO lenses of the same stream ####")
run_lens.(:kind)
run_lens.(:doc)
IO.puts("\nNote: verdicts are only meaningful once the corpus is large enough that")
IO.puts("2-back coverage is high. Keep the dev server / agent running to grow it.")
