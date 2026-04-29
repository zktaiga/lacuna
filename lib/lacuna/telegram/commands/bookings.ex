defmodule Lacuna.Telegram.Commands.Bookings do
  @moduledoc "List existing bookings with cancel buttons."

  alias Lacuna.Telegram.BookingsView

  def run(_msg, ctx) do
    BookingsView.send_list(ctx.update.message.chat.id)
    ctx
  end
end
