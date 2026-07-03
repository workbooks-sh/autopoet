defmodule Autopoet.MixProject do
  use Mix.Project

  def project do
    [
      app: :autopoet,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :wx],
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
      {:mint_web_socket, "~> 1.0"},
      # BEAM-native ML (the future-state stack, dogfooded here first): Whisper STT
      # for notes dictation runs in-process via Bumblebee/EXLA — no python, no
      # per-transcribe downloads; weights ship under data/models
      {:bumblebee, "~> 0.7"},
      # runtime: false — XLA's dylib bundles protobuf/absl symbols that SEGFAULT
      # onnxruntime if XLA loads first; the Ortex lane must bind before :exla
      # starts, so the whisper fallback starts :exla lazily (see Autopoet.Stt)
      {:exla, "~> 0.12", runtime: false},
      # ONNX lane: models with no Bumblebee port (moonshine STT) run their official
      # ONNX graphs in-process via ONNX Runtime
      # git main, NOT hex 0.1.10: the Elixir 1.19 fix (PR #48) was never released,
      # and 0.1.10's NIF segfaults Ortex.run on 1.19.5
      {:ortex, github: "elixir-nx/ortex"},
      {:tokenizers, "~> 0.5"}
    ]
  end
end
