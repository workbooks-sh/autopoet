defmodule Autopoet.Brain do
  @moduledoc """
  The proposal-only brain — the injectable `proposer` for `Nexus.Autopoet.Worker`
  (fills the v2 `:skip` stub, app-side; the runtime stays neutral).

  For each sensed item (telemetry concern / self-edit request) it asks an LLM
  through `Nexus.Llm.complete/2` (Groq-class planner by default; per-call
  base_url/key/model, nothing global) for a COMPLETE new version of the target
  `.work` file(s), parses strict `=== file: <relpath> ===` blocks, records the
  result as a pending proposal, and returns the changes so the Worker's Eval/Gate
  lane classifies them. v3 discipline: REGARDLESS of that classification, nothing
  merges — application happens only through `Autopoet.Proposals.accept/2` (human).

  No GROQ_API_KEY → the brain skips with a log line; the heartbeat stays harmless.
  Tests inject `:brain_llm` (app env) — no network in CI.
  """

  @model "llama-3.3-70b-versatile"
  @base_url "https://api.groq.com/openai/v1"

  def propose(item) do
    case llm() do
      nil ->
        Autopoet.Log.puts("brain: no GROQ_API_KEY and no injected LLM — skipping #{item[:target]}")
        :skip

      llm ->
        with {:ok, text} <- llm.(prompt(item)),
             changes when map_size(changes) > 0 <- parse_files(text) do
          Autopoet.Proposals.record(item, changes)
          {:ok, changes}
        else
          _ ->
            Autopoet.Log.puts("brain: no usable change for #{item[:target]}")
            :skip
        end
    end
  end

  @doc "Notify sink for human-gated items: they are already recorded as proposals; log the reasons."
  def notify(item, reasons) do
    Autopoet.Log.puts("human-gated: #{item[:target]} — #{inspect(reasons)}")
  end

  defp llm do
    case Application.get_env(:autopoet, :brain_llm) do
      fun when is_function(fun, 1) ->
        fun

      nil ->
        case System.get_env("GROQ_API_KEY") do
          key when is_binary(key) and key != "" -> fn p -> complete(p, key) end
          _ -> nil
        end
    end
  end

  defp complete(prompt, key) do
    case Nexus.Llm.complete([%{role: "user", content: prompt}],
           base_url: @base_url,
           api_key: key,
           model: System.get_env("AUTOPOET_BRAIN_MODEL") || @model,
           max_tokens: 3000,
           temperature: 0.2
         ) do
      {:ok, %{content: text}} when is_binary(text) -> {:ok, text}
      other -> other
    end
  end

  defp prompt(item) do
    """
    You maintain a small workbook of `.work` literate files. A concern was sensed:

    #{inspect(item, pretty: true)}

    Propose a minimal, complete fix. Reply ONLY with one or more file blocks, each:

    === file: <relative-path.work> ===
    <the COMPLETE new content of that file>

    No commentary outside the blocks. Keep files small and plain.
    """
  end

  @doc false
  def parse_files(text) do
    ~r/^=== file: (.+?) ===\n(.*?)(?=^=== file: |\z)/ms
    |> Regex.scan(text)
    |> Map.new(fn [_, path, body] -> {String.trim(path), String.trim_trailing(body) <> "\n"} end)
  end
end
