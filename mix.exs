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
      {:exla, "~> 0.12"}
    ]
  end
end
