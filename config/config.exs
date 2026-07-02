import Config

# The nexus Store rides SQLite (durable, under data/nexus/.nexus/) instead of the
# ETS default — this app is long-lived; its data must outlive the BEAM.
if config_env() != :test do
  config :nexus, store_adapter: Nexus.Store.Sqlite
end

if config_env() == :test do
  config :autopoet,
    headless: true,
    port: 4478,
    home: Path.expand("../_build/test_home", __DIR__),
    # tests NEVER go live — keys in the developer's shell env must not leak network
    # calls into the suite; inject :brain_llm instead
    brain_live: false
end
