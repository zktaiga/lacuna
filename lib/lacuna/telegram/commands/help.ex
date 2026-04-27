defmodule Lacuna.Telegram.Commands.Help do
  @moduledoc "Welcome message and command list."

  def run(_msg, ctx) do
    text = """
    *Lacuna*

    /free — what's available now? Pick a day → time → court.
    /watch — set up an alert for when slots open.
    /bookings — see and cancel your bookings.
    /help — this list.
    """

    ExGram.send_message(ctx.update.message.chat.id, text, parse_mode: "Markdown")
    ctx
  end
end
