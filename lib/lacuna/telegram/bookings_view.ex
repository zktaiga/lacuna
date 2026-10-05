defmodule Lacuna.Telegram.BookingsView do
  @moduledoc "Bookings: select a reservation, view details, then confirm cancellation."

  alias Lacuna.{Bookings, Clock}
  alias Lacuna.Telegram.Views
  alias Lacuna.Hunts.Store, as: HuntStore
  require Logger

  ## Send

  def send_list(chat_id) do
    case fetch_upcoming() do
      {:ok, []} ->
        ExGram.send_message(chat_id, "📋 *Bookings*\n\nNo upcoming bookings.",
          parse_mode: "Markdown",
          reply_markup: nav_keyboard()
        )

      {:ok, list} ->
        ExGram.send_message(chat_id, list_text(list),
          parse_mode: "Markdown",
          reply_markup: list_keyboard(list)
        )

      {:error, reason} ->
        ExGram.send_message(chat_id, "⚠️ Couldn't fetch bookings: `#{trunc_inspect(reason)}`",
          parse_mode: "Markdown",
          reply_markup: nav_keyboard()
        )
    end

    :ok
  end

  ## Edits (callbacks)

  def edit_to_list(message) do
    case fetch_upcoming() do
      {:ok, []} ->
        ExGram.edit_message_text("📋 *Bookings*\n\nNo upcoming bookings.",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: nav_keyboard()
        )

      {:ok, list} ->
        ExGram.edit_message_text(list_text(list),
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: list_keyboard(list)
        )

      {:error, reason} ->
        ExGram.edit_message_text("⚠️ Couldn't fetch bookings: `#{trunc_inspect(reason)}`",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: nav_keyboard()
        )
    end
  end

  def edit_to_details(message, booking_id) do
    with {:ok, list} <- fetch_upcoming(),
         booking when not is_nil(booking) <-
           Enum.find(list, &(to_string(&1["booking_id"]) == to_string(booking_id))) do
      ExGram.edit_message_text(details_text(booking),
        chat_id: message.chat.id,
        message_id: message.message_id,
        parse_mode: "Markdown",
        reply_markup: %ExGram.Model.InlineKeyboardMarkup{
          inline_keyboard: [
            [
              %ExGram.Model.InlineKeyboardButton{
                text: "Cancel booking…",
                callback_data: "bk:c:#{booking_id}"
              }
            ],
            [%ExGram.Model.InlineKeyboardButton{text: "← Bookings", callback_data: "bk:list"}]
          ]
        }
      )
    else
      _ -> edit_to_list(message)
    end
  end

  def edit_to_confirm(message, booking_id) do
    case fetch_upcoming() do
      {:ok, list} ->
        booking = Enum.find(list, &(&1["booking_id"] == booking_id))

        if booking do
          text = """
          *Cancel this booking?*

          #{details_text(booking)}

          This is irreversible.
          """

          markup = %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{
                  text: "Yes, cancel",
                  callback_data: "bk:do:#{booking_id}"
                },
                %ExGram.Model.InlineKeyboardButton{
                  text: "← Back",
                  callback_data: "bk:v:#{booking_id}"
                }
              ],
              [%ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}]
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
    case Lacuna.Bookings.cancel(booking_id) do
      {:ok, _} ->
        HuntStore.clear_active_booking_blocks()

        ExGram.edit_message_text("✅ Cancelled.",
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{text: "← Bookings", callback_data: "bk:list"},
                %ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}
              ]
            ]
          }
        )

      {:error, reason} ->
        ExGram.edit_message_text("❌ " <> Lacuna.Bookings.error_text(reason),
          chat_id: message.chat.id,
          message_id: message.message_id,
          parse_mode: "Markdown",
          reply_markup: %ExGram.Model.InlineKeyboardMarkup{
            inline_keyboard: [
              [
                %ExGram.Model.InlineKeyboardButton{text: "← Bookings", callback_data: "bk:list"},
                %ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}
              ]
            ]
          }
        )
    end
  end

  ## Data and rendering

  defp fetch_upcoming do
    with {:ok, list} <- Bookings.upcoming(cached: true), do: {:ok, sorted(list)}
  end

  @doc false
  def sorted(list),
    do:
      Enum.sort_by(list, fn booking ->
        {_court, date, start_time, _end_time} = Bookings.snapshot(booking)

        {date && Date.to_gregorian_days(date),
         start_time && Time.to_seconds_after_midnight(start_time)}
      end)

  @doc false
  def list_text(list),
    do: "*Your bookings · #{length(list)} upcoming*\n\nSelect a booking to view or cancel it."

  @doc false
  def list_keyboard(list) do
    rows =
      Enum.map(sorted(list), fn booking ->
        [
          %ExGram.Model.InlineKeyboardButton{
            text: selection_label(booking),
            callback_data: "bk:v:#{booking["booking_id"]}"
          }
        ]
      end)

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ nav_rows()}
  end

  defp selection_label(booking) do
    {_court, date, start_time, end_time} = Bookings.snapshot(booking)

    label =
      if date && start_time && end_time do
        [day, time] = String.split(Views.booking_time(date, start_time, end_time), " · ")
        day = if date == Clock.local_today(), do: "Today", else: day
        "#{day} · #{String.split(time, "–") |> hd()}"
      else
        "#{booking["start_date"]} · #{booking["start_time"]}"
      end

    label <> " · " <> Views.court_label(booking["facility_name"])
  end

  @doc false
  def details_text(booking) do
    {_court, date, start_time, end_time} = Bookings.snapshot(booking)

    when_text =
      if date && start_time && end_time,
        do: Views.booking_time(date, start_time, end_time),
        else: "#{booking["start_date"]} · #{booking["start_time"]}–#{booking["end_time"]}"

    reference = booking["booking_no"]

    "*#{Views.court_label(booking["facility_name"])}*\n\n#{when_text}" <>
      if(reference && reference != "", do: "\n\nReference: `#{reference}`", else: "")
  end

  defp nav_keyboard do
    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: nav_rows()}
  end

  defp nav_rows do
    [[%ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}]]
  end

  defp trunc_inspect(t), do: t |> inspect() |> String.slice(0, 200)
end
