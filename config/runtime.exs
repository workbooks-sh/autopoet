import Config

# Tests get a fully isolated nexus data dir (Nexus.Paths reads WB_DATA at runtime;
# runtime.exs evaluates before applications boot, so the seed/guide writers never
# touch the project root during `mix test`). WB_DATA sits UNDER home/data — exactly
# as run.sh wires it ($PWD/data/nexus) — so the body (.work) is inside the agent's
# own /work shell mount and it can read what it writes, faithful to the running app.
if config_env() == :test do
  # respect a caller-provided home (mix eval.iso — parallel clean-room runs each
  # bring their own AUTOPOET_HOME/WB_DATA); the default stays the shared test_home
  home = System.get_env("AUTOPOET_HOME") || Path.expand("../_build/test_home", __DIR__)
  System.put_env("WB_DATA", System.get_env("WB_DATA") || Path.join(home, "data/nexus"))
end
