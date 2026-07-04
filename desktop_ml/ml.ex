defmodule Autopoet.Ml do
  @moduledoc """
  The one place that decides which Nx runner backs the Bumblebee lane — so the
  EXLA→EMLX (Metal) swap is a config flip, never a code hunt.

    config :autopoet, :nx_runner, :exla | :emlx

  * `:exla` — CPU on macOS, proven. Started lazily (`runtime: false` in deps)
    because XLA must never dlopen before the ONNX lane binds its symbols
    (XLA-first segfaults onnxruntime — see `Autopoet.Stt` and
    nexus/docs/beam-local-ml.md).
  * `:emlx` — Apple-Silicon Metal via MLX. A BACKEND swap (eager dispatch),
    not a defn compiler: servings run under `Nx.Defn.Evaluator` with tensors
    on `EMLX.Backend`. Gated until (a) the dep is added, (b) its dylib is
    validated against the same onnxruntime bind-order trap EXLA fell into.

  Every Bumblebee serving should ask THIS module for its options instead of
  hardcoding a compiler.
  """

  @doc """
  Start the configured runner (always AFTER the ONNX lane has bound — callers
  are lazy paths by design) and return serving options:
  `%{defn_options: ..., preallocate: ...}` for `Bumblebee.Audio/Text.*` calls.
  """
  def runner_up! do
    case Application.get_env(:autopoet, :nx_runner, :exla) do
      :exla ->
        {:ok, _} = Application.ensure_all_started(:exla)
        %{defn_options: [compiler: EXLA]}

      :emlx ->
        case Application.ensure_all_started(:emlx) do
          {:ok, _} ->
            # eager Metal backend: params + computation dispatch to MLX; no
            # graph compiler involved
            Nx.default_backend({Module.concat([EMLX, Backend]), []})
            %{defn_options: [compiler: Nx.Defn.Evaluator]}

          _ ->
            raise "nx_runner is :emlx but the :emlx dep is not installed — " <>
                    "add {:emlx, github: \"elixir-nx/emlx\"} to mix.exs deps"
        end
    end
  end
end
