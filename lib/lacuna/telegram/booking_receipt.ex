defmodule Lacuna.Telegram.BookingReceipt do
  @moduledoc """
  Publishes a durable booking confirmation and consumes its interactive menu.

  Booking menus are edited in place while users navigate. A successful booking
  is different: it is an event worth preserving, so its receipt gets a fresh
  Telegram message and timestamp. Only after Telegram accepts that message do
  we remove the now-stale menu.
  """

  require Logger

  @spec publish(integer(), integer(), String.t(), module()) :: :ok | {:error, term()}
  def publish(chat_id, menu_message_id, text, telegram \\ ExGram) do
    case telegram.send_message(chat_id, text, parse_mode: "Markdown") do
      {:ok, _message} ->
        delete_consumed_menu(telegram, chat_id, menu_message_id)
        :ok

      {:error, reason} ->
        Logger.warning("Booking receipt send failed: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("Booking receipt send returned unexpectedly: #{inspect(other)}")
        {:error, other}
    end
  end

  defp delete_consumed_menu(telegram, chat_id, message_id) do
    case telegram.delete_message(chat_id, message_id) do
      {:ok, _} -> :ok
      :ok -> :ok
      result -> Logger.warning("Consumed booking menu could not be deleted: #{inspect(result)}")
    end
  end
end
