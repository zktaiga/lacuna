defmodule Lacuna.Telegram.Menu do
  @moduledoc "Main Telegram navigation menu."

  def send_menu(chat_id) do
    ExGram.send_message(chat_id, text(), parse_mode: "Markdown", reply_markup: markup())
    :ok
  end

  def edit_menu(message) do
    ExGram.edit_message_text(text(),
      chat_id: message.chat.id,
      message_id: message.message_id,
      parse_mode: "Markdown",
      reply_markup: markup()
    )
  end

  defp text do
    """
    *Lacuna*

    What do you want to do?
    """
  end

  defp markup do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{text: "🔎 Find slots", callback_data: "menu:free"},
          %ExGram.Model.InlineKeyboardButton{text: "👀 Watch", callback_data: "menu:watch"}
        ],
        [
          %ExGram.Model.InlineKeyboardButton{text: "📋 Bookings", callback_data: "menu:bookings"}
        ]
      ]
    }
  end
end
