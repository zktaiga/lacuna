import Config

config :lacuna,
  env: :test,
  prefs_path: Path.expand("../test/fixtures/prefs.toml", __DIR__),
  courts_path: Path.expand("../test/fixtures/courts.json", __DIR__),
  start_application: false

config :logger, level: :warning
