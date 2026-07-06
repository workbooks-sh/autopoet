import Config

# The nexus Store rides SQLite (durable, under data/nexus/.nexus/) instead of the
# ETS default — this app is long-lived; its data must outlive the BEAM.
if config_env() != :test do
  config :nexus, store_adapter: Nexus.Store.Sqlite
end

# WORKBOOKS CLOUD — one front door for EVERY model call. When the AI Gateway is
# configured (CF_AIG_URL + CF_AIG_TOKEN, from Secrets), `Nexus.Llm` routes ALL
# traffic — the brain, limbs, agents, embeds — through the `workbooks` gateway to
# the OpenRouter upstream (pass-through auth), model ids prefixed automatically.
# No gateway keys → this is inert and calls fall back to the direct base_url.
config :nexus, Nexus.Llm,
  gateway_upstream: "openrouter",
  api_key_env: "OPENROUTER_API_KEY"

if config_env() == :test do
  config :autopoet,
    headless: true,
    port: 4478,
    home: Path.expand("../_build/test_home", __DIR__),
    # tests NEVER go live — keys in the developer's shell env must not leak network
    # calls into the suite; inject :brain_llm instead
    brain_live: false

  # The resident micro-brain is OFF in test: `Shadow.Triage` checks this before
  # spawning a task or probing the network, so the suite's drift alarms behave
  # exactly as they did before Phase 1 (no `autopoet.attention.triaged` events).
  config :autopoet, Autopoet.Micro, enabled: false
end

# Nx stays on BinaryBackend by default: the ONNX lane (Ortex/moonshine) must own
# the process's native-lib symbol space; EXLA is started lazily by the whisper
# fallback only (XLA-before-onnxruntime segfaults — see Autopoet.Stt)

# which Nx runner backs the Bumblebee lane (whisper fallback, future embeddings/
# reranker). :exla = CPU, proven. :emlx = Metal — flip when it matures AND after
# validating bind-order against onnxruntime (see Autopoet.Ml + beam-local-ml.md);
# requires adding {:emlx, github: "elixir-nx/emlx"} to deps.
config :autopoet, :nx_runner, :exla
