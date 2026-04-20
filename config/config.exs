import Config

config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:request_id, :module]

config :ex_gram,
  json_engine: Jason

import_config "#{config_env()}.exs"
