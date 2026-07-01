import Config

if config_env() == :test do
  config :autopoet,
    headless: true,
    port: 4478,
    home: Path.expand("../_build/test_home", __DIR__)
end
