defmodule Lacuna.Telegram.Commands.Free do
  @moduledoc "Open the day picker for what's currently available."

  alias Lacuna.Telegram.Free

  def run(msg, ctx) do
    chat_id = ctx.update.message.chat.id

    case args(msg) do
      "" -> Free.send_root(chat_id)
      query -> Free.send_query(chat_id, query)
    end

    ctx
  end

  defp args(%{text: text}) when is_binary(text) do
    text
    |> String.replace(~r{^/free(@\w+)?\s*}, "")
    |> String.trim()
  end

  defp args(_), do: ""
end
