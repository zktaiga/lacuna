import Config

config :lacuna,
  env: :prod,
  prefs_path: System.get_env("LACUNA_PREFS_PATH", "/app/prefs.toml"),
  courts_path: System.get_env("LACUNA_COURTS_PATH", "/app/data/courts.json")

config :logger, level: :info
