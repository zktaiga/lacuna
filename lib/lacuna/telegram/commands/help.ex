defmodule Lacuna.Telegram.Commands.Help do
  @moduledoc "Welcome message and command list."

  def run(_msg, ctx) do
    text = """
    *Lacuna*

    /menu — open navigation.
    /free — what's available now? Pick a day → time → court.
    /free wed 18,19 thu 18,19 — quick search specific days/times.
    /hunts — manage standing slot hunts.
    /bookings — see and cancel your bookings.
    /help — this list.
    """

    ExGram.send_message(ctx.update.message.chat.id, text, parse_mode: "Markdown")
    ctx
  end
end
