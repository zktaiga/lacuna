defmodule Lacuna.Telegram.Commands.Menu do
  @moduledoc "Open the main navigation menu."

  alias Lacuna.Telegram.Menu

  def run(_msg, ctx) do
    Menu.send_menu(ctx.update.message.chat.id)
    ctx
  end
end
