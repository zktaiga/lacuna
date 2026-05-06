defmodule Lacuna.Telegram.Bot do
  @moduledoc """
  Top-level ex_gram bot. Routes slash commands and inline-button taps.

  Registered command surface:

      /menu      — main navigation
      /free      — what's available, multi-day picker
      /watch     — manage the standing watch (alerts when slots open)
      /bookings  — list & cancel upcoming bookings
      /help      — command list

  `/start` is special-cased by Telegram (sent on first chat creation)
  and routes to `/help`.
  """

  @bot :lacuna_bot

  use ExGram.Bot, name: @bot, setup_commands: false

  alias Lacuna.Telegram.{Access, Callbacks, Commands}
  require Logger

  middleware(ExGram.Middleware.IgnoreUsername)

  command("start")
  command("help")
  command("menu")
  command("free")
  command("watch")
  command("bookings")

  def bot, do: @bot

  def handle({:command, command, msg}, ctx) do
    if Access.authorized?(msg) do
      dispatch_command(command, msg, ctx)
    else
      Logger.warning("Ignoring command #{command} from unauthorized chat")
      ctx
    end
  end

  def handle({:callback_query, %ExGram.Model.CallbackQuery{} = cq}, ctx) do
    if Access.authorized?(cq) do
      Callbacks.handle(cq, ctx)
    else
      Logger.warning("Ignoring callback from unauthorized chat")
      ctx
    end
  end

  def handle(_other, ctx), do: ctx

  defp dispatch_command(:start, msg, ctx), do: Commands.Menu.run(msg, ctx)
  defp dispatch_command(:help, msg, ctx), do: Commands.Help.run(msg, ctx)
  defp dispatch_command(:menu, msg, ctx), do: Commands.Menu.run(msg, ctx)
  defp dispatch_command(:free, msg, ctx), do: Commands.Free.run(msg, ctx)
  defp dispatch_command(:watch, msg, ctx), do: Commands.Watch.run(msg, ctx)
  defp dispatch_command(:bookings, msg, ctx), do: Commands.Bookings.run(msg, ctx)
  defp dispatch_command(_, _msg, ctx), do: ctx
end
