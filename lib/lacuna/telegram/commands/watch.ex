defmodule Lacuna.Telegram.Commands.Watch do
  @moduledoc "Open the standing-watch configuration view."

  alias Lacuna.Telegram.WatchView

  def run(_msg, ctx) do
    WatchView.send_view(ctx.update.message.chat.id)
    ctx
  end
end
