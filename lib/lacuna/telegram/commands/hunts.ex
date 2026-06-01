defmodule Lacuna.Telegram.Commands.Hunts do
  @moduledoc "Open the hunts view."

  alias Lacuna.Telegram.HuntsView

  def run(_msg, ctx) do
    HuntsView.send_list(ctx.update.message.chat.id)
    ctx
  end
end
