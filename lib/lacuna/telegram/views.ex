defmodule Lacuna.Telegram.Views do
  @moduledoc """
  Pure rendering helpers + a couple of one-shot send helpers used by the
  bus notifier. Nothing here owns state.
  """

  alias Lacuna.{Slot, Telegram.Access}
  alias Lacuna.Hunts.Store, as: HuntStore
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
    bookings = Lacuna.Bookings.upcoming(cached: true)
    rows = Enum.map(slots, fn slot -> [booking_button(slot, bookings)] end)
    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows}
  end

  def booking_button(slot, bookings, opts \\ []) do
    label =
      case bookings do
        {:ok, list} ->
          case Lacuna.Bookings.eligibility(slot, list) do
            :bookable -> "Book"
            {:already_booked, _} -> "Already yours ✓"
            {:replacement_required, _} -> "Replace…"
            {:blocked, _} -> "Review bookings"
          end

        _ ->
          "Check & book"
      end

    %ExGram.Model.InlineKeyboardButton{
      text:
        "#{court_label(slot.facility_name)} · #{if Keyword.get(opts, :show_time, true), do: format_time(slot.start_time) <> " · ", else: ""}#{label}",
      callback_data: "book:" <> Slot.key(slot)
    }
  end

  def court_label(name) do
    case Regex.run(~r/^Neighborhood\s+(\d+)\s*-\s*Padel Court(?:\s+(\d+))?$/i, String.trim(name)) do
      [_, community, court] -> "Neighborhood #{community} / Court #{court}"
      [_, community] -> "Neighborhood #{community}"
      _ -> name
    end
  end

  def replacement_text(slot, booking) do
    {_court, date, start_time, end_time} = Lacuna.Bookings.snapshot(booking)

    current =
      if date && start_time && end_time,
        do: booking_time(date, start_time, end_time),
        else: Lacuna.Bookings.summary(booking)

    "*Replace booking — #{court_label(slot.facility_name)}*\n\n*Current:* #{current}\n*New:* #{booking_time(slot.date, slot.start_time, slot.end_time)}\n\nYour current booking must be cancelled first. If the new slot is taken before we book it, you could lose both."
  end

  def booking_time(date, start_time, end_time) do
    days = ~w(Mon Tue Wed Thu Fri Sat Sun)
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    "#{Enum.at(days, Date.day_of_week(date) - 1)} #{date.day} #{Enum.at(months, date.month - 1)} · #{format_time(start_time)}–#{format_time(end_time)}"
  end

  def booking_notices(slots) do
    case Lacuna.Bookings.upcoming(cached: true) do
      {:ok, list} ->
        slots
        |> Enum.map(fn slot ->
          case Lacuna.Bookings.eligibility(slot, list) do
            {:replacement_required, booking} ->
              "↔️ To book another slot on this court, cancel or replace:\n" <>
                Lacuna.Bookings.summary(booking)

            {:already_booked, booking} ->
              "✅ Already booked: " <> Lacuna.Bookings.summary(booking)

            {:blocked, _} ->
              "⚠️ Multiple bookings on #{slot.facility_name}; review /bookings."

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.join("\n\n")
        |> case do
          "" -> ""
          text -> "\n\n" <> text
        end

      _ ->
        "\n\n⚠️ Existing bookings could not be checked. They will be refreshed before any booking."
    end
  end

  ## Bus event handlers

  @doc "Called by `Plugins.TelegramNotifier` for every event. Pure dispatch."
  def handle_event({:hunt_slot_opened, hunt, %Slot{} = slot}) do
    if hunt.mode == :auto_book do
      auto_book(hunt, slot)
    else
      text = "*New slot* · #{hunt.name}\n" <> render_slot(slot) <> booking_notices([slot])

      ExGram.send_message(Access.configured_chat_id(), text,
        parse_mode: "Markdown",
        reply_markup: book_keyboard([slot])
      )

      stop_hunt_if_needed(hunt)
    end
  end

  def handle_event({:slot_opened, %Slot{} = slot}) do
    text = "*New slot*\n" <> render_slot(slot) <> booking_notices([slot])

    ExGram.send_message(Access.configured_chat_id(), text,
      parse_mode: "Markdown",
      reply_markup: book_keyboard([slot])
    )
  end

  def handle_event({:poll_failed, reason}) do
    ExGram.send_message(
      Access.configured_chat_id(),
      "⚠️ Poll failed: `#{inspect(reason) |> String.slice(0, 200)}`",
      parse_mode: "Markdown"
    )
  end

  def handle_event(_other), do: :ok

  defp auto_book(hunt, %Slot{} = slot) do
    case Lacuna.Bookings.book(slot, %{actor: :hunt_auto_book, hunt_id: hunt.id}) do
      {:ok, _booking} ->
        ExGram.send_message(
          Access.configured_chat_id(),
          "✅ *Auto-booked* · #{hunt.name}\n" <> render_slot(slot),
          parse_mode: "Markdown"
        )

        HuntStore.clear_block(hunt.id)
        stop_hunt_if_needed(hunt)

      {:error, reason} ->
        ExGram.send_message(
          Access.configured_chat_id(),
          "❌ *Auto-book failed* · #{hunt.name}\n#{render_slot(slot)}\n#{format_booking_error(reason)}",
          parse_mode: "Markdown",
          reply_markup: book_keyboard([slot])
        )
    end
  end

  ## Helpers

  defp stop_hunt_if_needed(%{after_match: :stop_on_first} = hunt),
    do: HuntStore.deactivate(hunt.id)

  defp stop_hunt_if_needed(_hunt), do: :ok

  defp format_booking_error(reason), do: Lacuna.Bookings.error_text(reason)

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
end
