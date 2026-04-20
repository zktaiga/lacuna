import Config

config :lacuna,
  env: :dev,
  prefs_path: Path.expand("../prefs.toml", __DIR__),
  courts_path: Path.expand("../courts.json", __DIR__)

config :logger, level: :debug
