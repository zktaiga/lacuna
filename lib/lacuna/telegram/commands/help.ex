defmodule Lacuna.Telegram.Commands.Help do
  @moduledoc "Welcome message and command list."

  def run(_msg, ctx) do
    text = """
    *Lacuna*

    🔎 /free — browse open slots.
    ⚡ /free wed 18,19 thu 18,19 — quick day/time search.
    🎯 /hunts — manage standing slot hunts.
    📋 /bookings — see and cancel bookings.
    🧭 /menu — open navigation.
    """

    markup = %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [%ExGram.Model.InlineKeyboardButton{text: "🧭 Open menu", callback_data: "menu:root"}]
      ]
    }

    ExGram.send_message(ctx.update.message.chat.id, text,
      parse_mode: "Markdown",
      reply_markup: markup
    )

    ctx
  end
end
