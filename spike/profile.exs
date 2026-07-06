# BEAM-native companion profiling — Scholar GaussianMixture learns the behavioral
# types (spine vs decision) from the per-locus features, over the real captured
# corpus. No Python. Re-run as the corpus grows; the clustering sharpens with data.
#
#   Run: cd autopoet && mix run --no-start spike/profile.exs
#   (optional) TRACE_ROOT=.../_build/test_home  to use the larger eval corpus

dir = Autopoet.Shadow.Trace.dir(System.get_env("TRACE_ROOT"))
signals = Autopoet.Shadow.Trace.events(dir) |> Autopoet.Shadow.Trace.signals(:kind)
IO.puts("\n#### Scholar companion — learned behavioral clustering (in-BEAM) ####")
IO.puts("corpus: #{length(signals)} kind-signals from #{dir}")

case Autopoet.Shadow.Profile.cluster(signals, k: 3) do
  :insufficient_loci ->
    IO.puts("\n(too few distinct loci to cluster yet — grow the corpus; pipeline is ready)")

  %{loci: rows, types: types} ->
    IO.puts("learned types: #{inspect(Map.values(types) |> Enum.uniq())}")
    IO.puts("\nlocus                    | type                 | H(next) | log10(cnt)")
    IO.puts(String.duplicate("-", 70))

    rows
    |> Enum.sort_by(& &1.entropy)
    |> Enum.each(fn r ->
      :io.format("~-24s | ~-20s | ~-7.3f | ~.2f~n",
        [String.slice(r.locus, 0, 24), r.type, r.entropy, r.log_count])
    end)

    IO.puts("\n=> GaussianMixture discovered these behavioral bands from the data —")
    IO.puts("   the learned replacement for hand-picked entropy thresholds. Scales")
    IO.puts("   with the corpus; ready to point at a larger run set.")
end
