import Config

# Tests get a fully isolated nexus data dir (Nexus.Paths reads WB_DATA at runtime;
# runtime.exs evaluates before applications boot, so the seed/guide writers never
# touch the project root during `mix test`).
if config_env() == :test do
  System.put_env("WB_DATA", Path.expand("../_build/test_home/nexus", __DIR__))
end
