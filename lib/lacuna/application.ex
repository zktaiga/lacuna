defmodule Lacuna.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:lacuna, :start_application, true) do
      start_real_tree()
    else
      Supervisor.start_link([], strategy: :one_for_one, name: Lacuna.Supervisor)
    end
  end

  defp start_real_tree do
    children = [
      Lacuna.Bus,
      {Lacuna.Watch.Config, []},
      {Lacuna.Backend.Session, []},
      {Lacuna.Watcher.Poller, []},
      {Lacuna.Plugins.TelegramNotifier, []},
      ExGram,
      {Lacuna.Telegram.Bot,
       [method: :polling, token: Application.fetch_env!(:lacuna, :telegram_bot_token)]}
    ]

    opts = [strategy: :one_for_one, name: Lacuna.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _sup} = ok ->
        configure_session_from_env()
        register_telegram_commands()
        ok

      err ->
        err
    end
  end

  # Best-effort. If the Telegram API is reachable, the four registered
  # commands appear in the autocomplete list across all clients. Failures
  # are non-fatal because the bot still works without registration.
  defp register_telegram_commands do
    Task.start(fn ->
      Process.sleep(2_000)

      commands = [
        %ExGram.Model.BotCommand{command: "start", description: "Show command list"},
        %ExGram.Model.BotCommand{command: "menu", description: "Open navigation menu"},
        %ExGram.Model.BotCommand{
          command: "free",
          description: "What's available — pick a day, time, court"
        },
        %ExGram.Model.BotCommand{
          command: "watch",
          description: "Standing alert for new openings"
        },
        %ExGram.Model.BotCommand{command: "bookings", description: "List & cancel your bookings"},
        %ExGram.Model.BotCommand{command: "help", description: "Show command list"}
      ]

      case ExGram.set_my_commands(commands) do
        {:ok, _} -> Logger.info("Telegram commands registered")
        {:error, reason} -> Logger.warning("setMyCommands failed: #{inspect(reason)}")
      end
    end)
  end

  defp configure_session_from_env do
    email = Application.get_env(:lacuna, :operator_email)
    password = Application.get_env(:lacuna, :operator_password)

    cond do
      is_binary(email) and email != "" and is_binary(password) and password != "" ->
        Lacuna.Backend.Session.configure(email, password)

      true ->
        Logger.warning(
          "Operator credentials not set — populate LACUNA_OPERATOR_EMAIL/PASSWORD in .env before /start"
        )
    end
  end
end
