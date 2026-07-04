defmodule Autopoet.Eval.Drain do
  @moduledoc """
  wb-phbt5 — the fix/repair elasticity loop: failures the eval loop surfaces
  are filed through the EXISTING `request self` channel (target `eval:<name>`),
  and this drain converts them into bd issues — so the eval loop's output is a
  continuously replenished work queue against the real system.

  `drain/1` pulls the pending request queue, files a bd issue per `eval:`
  request through `runner` (injectable — tests stub it; default runs the real
  `bd` CLI), and RE-FILES every non-eval request untouched (the brain's queue
  is not ours to eat). Returns `{filed, kept}` counts.
  """

  def file_failure(name, detail),
    do: Autopoet.Requests.file("eval:#{name}", detail)

  def drain(runner \\ &bd/2) do
    {evals, rest} =
      Autopoet.Requests.drain()
      |> Enum.split_with(fn r -> String.starts_with?(to_string(r[:target] || ""), "eval:") end)

    # the brain's own queue goes straight back — drained, inspected, returned
    for r <- rest, do: Autopoet.Requests.file(r[:target], r[:change])

    filed =
      for r <- evals do
        name = String.trim_leading(to_string(r[:target]), "eval:")

        runner.("bd", [
          "create",
          "[eval] #{name}",
          "-t",
          "bug",
          "-p",
          "2",
          "-d",
          "Filed by the eval loop (wb-phbt5 drain). #{r[:change]}"
        ])
      end

    {length(filed), length(rest)}
  end

  defp bd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  rescue
    e -> {:error, {:no_bd, Exception.message(e)}}
  end
end
