defmodule Autopoet.MixProject do
  use Mix.Project

  # CLOUD target (AUTOPOET_TARGET=cloud) is the headless Fly image: no desktop GUI (:wx), no local ML stack
  # (Whisper/Kokoro/ONNX — desktop-only). Those modules live in desktop_ml/; cloud swaps in thin stubs from
  # cloud_stubs/, so the headless image builds without bumblebee/exla/ortex/tokenizers/:wx.
  @cloud System.get_env("AUTOPOET_TARGET") == "cloud"

  def project do
    [
      app: :autopoet,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      preferred_cli_env: [eval: :test],
      deps: deps()
    ]
  end

  # test/support holds eval fixtures (the golden personas — Lane E seeds). desktop compiles desktop_ml/
  # (real ML/voice); cloud compiles cloud_stubs/ (thin stubs) instead.
  defp elixirc_paths(:test), do: base_paths() ++ ["test/support"]
  defp elixirc_paths(_), do: base_paths()
  defp base_paths, do: ["lib" | if(@cloud, do: ["cloud_stubs"], else: ["desktop_ml"])]

  # `mix eval` — the whole-system scorecard (wb-q351b.6): every eval dimension in
  # one run, numbers appended to eval/history.log for cross-commit comparison.
  # AUTOPOET_SOAK_SECONDS scales the soak leg (default 15s; 3600+ overnight).
  defp aliases do
    [eval: &run_eval/1]
  end

  defp run_eval(args) do
    System.put_env("EVAL_HISTORY", "1")

    Mix.Task.run("test", [
      "test/genesis_eval_test.exs",
      "test/agent_world_eval_test.exs",
      "test/persona_eval_test.exs",
      "test/replay_eval_test.exs",
      "test/integrity_eval_test.exs",
      "test/heartbeat_eval_test.exs",
      "test/containment_eval_test.exs",
      "test/efficiency_eval_test.exs",
      "test/armlift_eval_test.exs",
      "test/select_eval_test.exs",
      "test/soak_eval_test.exs" | args
    ])
  end

  # One release definition, two package targets:
  #   * CLOUD  → this release assembled inside a Linux Docker image (Dockerfile),
  #              run on a vendored Fly machine (AUTOPOET_TARGET=cloud).
  #   * DESKTOP → the SAME release wrapped by burrito into a single self-contained
  #               macOS binary that lives in Autopoet.app/Contents/MacOS (so users
  #               need no Elixir install). Enable by adding {:burrito, "~> 1.0"} and
  #               a `burrito:` block when we cut the desktop distributable.
  defp releases do
    [
      autopoet: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def application do
    [
      # :wx is the desktop GUI (wxWidgets) — absent from the headless cloud image, so cloud omits it.
      extra_applications: [:logger | if(@cloud, do: [], else: [:wx])],
      mod: {Autopoet.Application, []}
    ]
  end

  defp deps do
    [
      # The Workbooks runtime as a LIBRARY (the typeaway pattern): event bus, store,
      # scheduler, the v2 autopoet worker/gate/leases, Llm + the admission money
      # boundary. Nothing autopoet-desktop-specific ever goes into the nexus repo.
      {:nexus, path: "../workbooks/nexus"},
      # realtime voice: browser ⇄ Plug WebSocket (websock_adapter over Bandit) and
      # Elixir ⇄ Gemini Live wss client (mint_web_socket)
      {:websock_adapter, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"}
    ] ++ ml_deps()
  end

  # Local ML — Whisper STT (Bumblebee/EXLA), ONNX (Ortex), tokenizers. DESKTOP-ONLY: heavy native builds
  # (XLA ~500MB, a Rust NIF) that the headless cloud brain neither needs nor should carry. Cloud → none.
  defp ml_deps do
    if @cloud do
      []
    else
      [
        {:bumblebee, "~> 0.7"},
        # runtime: false — XLA's dylib bundles protobuf/absl symbols that SEGFAULT onnxruntime if XLA loads
        # first; the Ortex lane must bind before :exla starts (whisper fallback starts :exla lazily, Stt).
        {:exla, "~> 0.12", runtime: false},
        # git main, NOT hex 0.1.10: the Elixir 1.19 fix (PR #48) was never released, and 0.1.10's NIF
        # segfaults Ortex.run on 1.19.5.
        {:ortex, github: "elixir-nx/ortex"},
        {:tokenizers, "~> 0.5"}
      ]
    end
  end
end
