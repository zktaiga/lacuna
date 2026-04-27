defmodule Lacuna.Telegram.Access do
  @moduledoc """
  Whitelist guard for the Telegram bot.

  Only updates whose `chat.id` matches the configured group are allowed
  through. Everything else is silently dropped.
  """

  def configured_chat_id, do: Application.fetch_env!(:lacuna, :telegram_group_chat_id)

  def authorized?(%{chat: %{id: id}}), do: id == configured_chat_id()
  def authorized?(%{message: %{chat: %{id: id}}}), do: id == configured_chat_id()
  def authorized?(%ExGram.Model.Message{chat: %{id: id}}), do: id == configured_chat_id()

  def authorized?(%ExGram.Model.CallbackQuery{message: %{chat: %{id: id}}}),
    do: id == configured_chat_id()

  def authorized?(_), do: false
end
