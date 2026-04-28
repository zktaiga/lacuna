defmodule Lacuna.Telegram.Commands.Free do
  @moduledoc "Open the day picker for what's currently available."

  alias Lacuna.Telegram.Free

  def run(_msg, ctx) do
    Free.send_root(ctx.update.message.chat.id)
    ctx
  end
end
