defmodule Lacuna.Telegram.Views do
  @moduledoc """
  Pure rendering helpers + a couple of one-shot send helpers used by the
  bus notifier. Nothing here owns state.
  """

  alias Lacuna.{Slot, Telegram.Access, Watch.Config}
  require Logger

  @doc """
  Format a single slot as a human-readable line.

      🎾 Sat 09 May · 18:00–19:00 · Court A
  """
  @spec render_slot(Slot.t()) :: String.t()
  def render_slot(%Slot{} = s) do
    day = day_short(Date.day_of_week(s.date))
    date = "#{day} #{pad(s.date.day)} #{month_short(s.date.month)}"
    time = "#{format_time(s.start_time)}–#{format_time(s.end_time)}"
    "🎾 #{date} · #{time} · #{s.facility_name}"
  end

  @doc """
  Render a list of slots, grouped by court, suitable for `/today`/`/tomorrow`.
  """
  @spec render_day(Date.t(), [Slot.t()]) :: String.t()
  def render_day(%Date{} = d, []) do
    "Nothing free on #{Date.to_iso8601(d)} 😔"
  end

  def render_day(%Date{} = d, slots) do
    grouped = Enum.group_by(slots, & &1.facility_name)

    body =
      grouped
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.map_join("\n\n", fn {name, list} ->
        rows =
          list
          |> Enum.sort_by(& &1.start_time, Time)
          |> Enum.map_join("\n", fn s ->
            "  #{format_time(s.start_time)}–#{format_time(s.end_time)}"
          end)

        "*#{name}*\n#{rows}"
      end)

    "*#{Date.to_iso8601(d)}*\n\n" <> body
  end

  @doc "Inline keyboard with one Book button per slot."
  @spec book_keyboard([Slot.t()]) :: ExGram.Model.InlineKeyboardMarkup.t()
  def book_keyboard(slots) do
    rows =
      Enum.map(slots, fn s ->
        [
          %ExGram.Model.InlineKeyboardButton{
            text: "Book #{format_time(s.start_time)} #{abbrev(s.facility_name)}",
            callback_data: "book:" <> Slot.key(s)
          }
        ]
      end)

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows}
  end

  ## Bus event handlers

  @doc "Called by `Plugins.TelegramNotifier` for every event. Pure dispatch."
  def handle_event({:slot_opened, %Slot{} = slot}) do
    if Config.get().auto_book? do
      auto_book(slot)
    else
      text = "*New slot*\n" <> render_slot(slot)

      ExGram.send_message(Access.configured_chat_id(), text,
        parse_mode: "Markdown",
        reply_markup: book_keyboard([slot])
      )
    end
  end

  def handle_event({:poll_failed, reason}) do
    ExGram.send_message(
      Access.configured_chat_id(),
      "⚠️ Poll failed: `#{inspect(reason) |> String.slice(0, 200)}`",
      parse_mode: "Markdown"
    )
  end

  def handle_event(_other), do: :ok

  defp auto_book(%Slot{} = slot) do
    prefs = Lacuna.Config.load!()
    booker = prefs.plugins.booker || Lacuna.Plugins.DefaultBooker

    case apply(booker, :book, [slot, %{actor: :watch_auto_book}]) do
      {:ok, _booking} ->
        ExGram.send_message(
          Access.configured_chat_id(),
          "✅ *Auto-booked*\n" <> render_slot(slot),
          parse_mode: "Markdown"
        )

      {:error, reason} ->
        ExGram.send_message(
          Access.configured_chat_id(),
          "❌ *Auto-book failed*\n#{render_slot(slot)}\n#{format_booking_error(reason)}",
          parse_mode: "Markdown",
          reply_markup: book_keyboard([slot])
        )
    end
  end

  ## Helpers

  defp format_booking_error({:booking_not_confirmed, _response}) do
    "The provider accepted the request, but the booking did not appear in upcoming bookings. It may have been rejected by a booking rule."
  end

  defp format_booking_error(reason), do: "`#{inspect(reason) |> String.slice(0, 200)}`"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  def format_time(%Time{} = t) do
    "#{pad(t.hour)}:#{pad(t.minute)}"
  end

  defp day_short(1), do: "Mon"
  defp day_short(2), do: "Tue"
  defp day_short(3), do: "Wed"
  defp day_short(4), do: "Thu"
  defp day_short(5), do: "Fri"
  defp day_short(6), do: "Sat"
  defp day_short(7), do: "Sun"

  defp month_short(1), do: "Jan"
  defp month_short(2), do: "Feb"
  defp month_short(3), do: "Mar"
  defp month_short(4), do: "Apr"
  defp month_short(5), do: "May"
  defp month_short(6), do: "Jun"
  defp month_short(7), do: "Jul"
  defp month_short(8), do: "Aug"
  defp month_short(9), do: "Sep"
  defp month_short(10), do: "Oct"
  defp month_short(11), do: "Nov"
  defp month_short(12), do: "Dec"

  defp abbrev(name) when is_binary(name) do
    name
    |> String.split()
    |> Enum.map(fn
      <<c::utf8, _::binary>> -> <<c::utf8>>
      _ -> ""
    end)
    |> Enum.join()
    |> String.upcase()
  end

  defp abbrev(_), do: "?"
end
