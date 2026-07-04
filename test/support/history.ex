defmodule Autopoet.Eval.History do
  @moduledoc """
  Eval D6 (wb-q351b.6) — the eval history: one line per scorecard number per
  `mix eval` run, appended to `eval/history.log` (plain lines, greppable,
  diffable across commits — never JSON). Recording only happens under
  `mix eval` (EVAL_HISTORY=1); plain `mix test` stays silent so CI noise never
  pollutes the record.

      2026-07-04T21:00:00Z · fc85928 · replay/structured · hebb=0.784 frequency=0.219 …
  """

  @path Path.join("eval", "history.log")

  def record(name, kv) when is_map(kv) or is_list(kv) do
    if System.get_env("EVAL_HISTORY") do
      ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      line = "#{ts} · #{sha()} · #{name} · " <> Enum.map_join(kv, " ", fn {k, v} -> "#{k}=#{fmt(v)}" end)
      File.mkdir_p!(Path.dirname(@path))
      File.write!(@path, line <> "\n", [:append])
    end

    :ok
  end

  defp sha do
    case System.cmd("git", ~w(rev-parse --short HEAD), stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "?"
    end
  rescue
    _ -> "?"
  end

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 4)
  defp fmt(v), do: to_string(v)
end
