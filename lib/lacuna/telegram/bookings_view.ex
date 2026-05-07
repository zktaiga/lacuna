defmodule Lacuna.Telegram.BookingsView do
  @moduledoc """
  `/bookings` — list upcoming bookings, with two-step Cancel buttons.

      list                 confirm                 done
      ┌──────────────┐    ┌─────────────────┐    ┌──────────────┐
      │ Sat 09 18:00 │    │ Cancel Sat 18?  │    │ ✅ Cancelled │
      │ H3-PC-1      │    │                 │    │              │
      │ [Cancel]     │ ─▶ │ [Yes, cancel]   │ ─▶ │ [← back]     │
      │              │    │ [Keep it]       │    │              │
      └──────────────┘    └─────────────────┘    └──────────────┘

  We list `upcoming_bookings` only (the upstream's `type:
  "upcoming_bookings"`). Past bookings aren't actionable.
  """

  alias Lacuna.Backend.{API, Session}
  require Logger

  ## Send

  def send_list(chat_id) do
    case fetch_upcoming() do
      {:ok, []} ->
        ExGram.send_message(chat_id, "*Bookings*\n\nNo upcoming bookings.",
          parse_mode: "Markdown"
        )

      {:ok, list} ->
        ExGram.send_message(chat_id, list_text(list),
          parse_mode: "Markdown",
          reply_markup: list_keyboard(list)
        )

      {:error, reason} ->
        ExGram.send_message(chat_id, "Couldn't fetch bookings: `#{trunc_inspect(reason)}`",
          parse_mode: "Markdown"
        )
    end

    :ok
  end

  ## Edits (callbacks)

  def edit_to_list(message) do
    case fetch_upcoming() do
      {:ok, []} ->
        ExGram.edit_message_text("*Bookings*\n\nNo upcoming bookings.",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown"
        )

      {:ok, list} ->
        ExGram.edit_message_text(list_text(list),
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: list_keyboard(list)
        )

      {:error, reason} ->
        ExGram.edit_message_text("Couldn't fetch bookings: `#{trunc_inspect(reason)}`",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown"
        )
    end
  end

  def edit_to_confirm(message, booking_id) do
    case fetch_upcoming() do
      {:ok, list} ->
        booking = Enum.find(list, &(&1["booking_id"] == booking_id))

        if booking do
          text = """
          *Cancel this booking?*

          #{render_one(booking)}

          This is irreversible.
          """

          markup = %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{
                  text: "Yes, cancel",
                  callback_data: "bk:do:#{booking_id}"
                },
                %ExGram.Model.InlineKeyboardButton{text: "Keep it", callback_data: "bk:list"}
              ]
            ]
          }

          ExGram.edit_message_text(text,
            chat_id: message.chat.id,
            message_id: message.message_id,
            parse_mode: "Markdown",
            reply_markup: markup
          )
        else
          edit_to_list(message)
        end

      _ ->
        edit_to_list(message)
    end
  end

  def execute_cancel(message, booking_id) do
    session = Session.current!()

    case API.cancel_booking(session, booking_id) do
      {:ok, _} ->
        ExGram.edit_message_text("✅ Cancelled.",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{text: "← Bookings", callback_data: "bk:list"}
              ]
            ]
          }
        )

      {:error, reason} ->
        ExGram.edit_message_text("❌ Cancel failed: `#{trunc_inspect(reason)}`",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{text: "← Bookings", callback_data: "bk:list"}
              ]
            ]
          }
        )
    end
  end

  ## Data

  defp fetch_upcoming do
    session = Session.current!()

    with {:ok, data} <- API.my_bookings(session) do
      groups = Map.get(data, "my_bookings", %{})

      list =
        groups
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&actionable_upcoming?/1)
        |> Enum.sort_by(fn b -> {Map.get(b, "start_date"), Map.get(b, "start_time")} end)

      {:ok, list}
    end
  end

  defp actionable_upcoming?(booking) do
    Map.get(booking, "type") == "upcoming_bookings" and
      booking_status(booking) not in ["cancelled", "canceled"]
  end

  defp booking_status(booking) do
    booking
    |> Map.get("status", "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  ## Rendering

  defp list_text(list) do
    body =
      list
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {b, i} -> "*#{i}.* #{render_one(b)}" end)

    "*Bookings* (#{length(list)} upcoming)\n\n" <> body
  end

  defp list_keyboard(list) do
    rows =
      Enum.map(list, fn b ->
        bid = Map.get(b, "booking_id", "")

        [
          %ExGram.Model.InlineKeyboardButton{
            text: "Cancel #{shorten(b)}",
            callback_data: "bk:c:#{bid}"
          }
        ]
      end)

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows}
  end

  defp render_one(b) do
    "#{Map.get(b, "start_date")} · #{Map.get(b, "start_time")}–#{Map.get(b, "end_time")} · #{Map.get(b, "facility_name")} (`#{Map.get(b, "booking_no")}`)"
  end

  defp shorten(b) do
    "#{Map.get(b, "start_date")} #{Map.get(b, "start_time")}"
  end

  defp trunc_inspect(t), do: t |> inspect() |> String.slice(0, 200)
end
