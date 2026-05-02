ExUnit.start()

Application.put_env(:lacuna, :start_application, false)
Application.put_env(:lacuna, :prefs_path, Path.expand("fixtures/prefs.toml", __DIR__))
Application.put_env(:lacuna, :courts_path, Path.expand("fixtures/courts.json", __DIR__))
