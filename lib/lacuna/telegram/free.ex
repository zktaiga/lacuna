defmodule Lacuna.Telegram.Free do
  @moduledoc """
  `/free` flow. Court-agnostic, time-first.

      day picker            time grid              court picker          done
      ┌─────────────┐      ┌────────────────┐    ┌──────────────┐    ┌──────────┐
      │ Pick a day  │      │ Today          │    │ Today · 19   │    │ ✅ Booked│
      │ [Today]     │ ──▶  │ [17 (2)]       │ ─▶ │ [Court A]    │ ─▶ │          │
      │ [Tomorrow]  │      │ [18 (1)]       │    │ [Court B]    │    │          │
      │ [Sat 09]    │      │ [19 (4)]       │    │ ← Times      │    │          │
      │ ...         │      │ ← Days         │    └──────────────┘    └──────────┘
      └─────────────┘      └────────────────┘

  All edits happen on the same message via `edit_message_text`. No
  polling — every transition fetches live.
  """

  alias Lacuna.{Clock, Slot, Telegram.Views}
  alias Lacuna.Backend.{API, Availability, Courts, Session}

  @lookahead_days 14

  ## Commands

  @spec send_root(integer()) :: :ok
  def send_root(chat_id) do
    text = "*Find slots*\n\nPick a day."
    markup = day_keyboard()
    ExGram.send_message(chat_id, text, parse_mode: "Markdown", reply_markup: markup)
    :ok
  end

  ## Edits (callback handlers)

  def edit_to_root(message) do
    edit(message, "*Find slots*\n\nPick a day.", day_keyboard())
  end

  def edit_to_day(message, %Date{} = date) do
    case fetch_open(date) do
      {:ok, by_court} ->
        flat = flatten(by_court)
        edit(message, day_text(date, flat), day_time_keyboard(date, flat))

      {:error, reason} ->
        edit(message, "Couldn't fetch: `#{trunc_inspect(reason)}`", back_to_root())
    end
  end

  def edit_to_time(message, %Date{} = date, %Time{} = at) do
    case fetch_open(date) do
      {:ok, by_court} ->
        slots =
          flatten(by_court) |> Enum.filter(fn s -> Time.compare(s.start_time, at) == :eq end)

        edit(message, time_text(date, at, slots), court_keyboard(date, at, slots))

      {:error, reason} ->
        edit(message, "Couldn't fetch: `#{trunc_inspect(reason)}`", back_to_root())
    end
  end

  ## Data

  defp fetch_open(%Date{} = date) do
    with {:ok, courts} <- ensure_courts(),
         session <- Session.current!(),
         {:ok, raw} <- gather(session, courts, date) do
      filtered =
        Enum.map(raw, fn {court, slots} ->
          {court, slots |> filter_past(date) |> Enum.sort_by(& &1.start_time, Time)}
        end)

      {:ok, Map.new(filtered, fn {c, s} -> {c.id, {c.name, s}} end)}
    end
  end

  defp filter_past(slots, %Date{} = date) do
    today = Clock.local_today()

    if Date.compare(date, today) == :eq do
      now = Clock.local_time()
      Enum.filter(slots, fn s -> Time.compare(s.start_time, now) == :gt end)
    else
      slots
    end
  end

  ## Rendering

  defp day_keyboard do
    today = Clock.local_today()
    range = 0..(@lookahead_days - 1)

    buttons =
      for delta <- range do
        date = Date.add(today, delta)

        %ExGram.Model.InlineKeyboardButton{
          text: short_label(date, delta),
          callback_data: "free:d:#{Date.to_iso8601(date)}"
        }
      end

    rows = Enum.chunk_every(buttons, 3)
    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [menu_row()]}
  end

  defp day_text(date, slots) do
    n = length(slots)

    if n == 0 do
      "*#{long_label(date)}* — fully booked 😔"
    else
      "*#{long_label(date)}* — #{n} slot#{plural(n)} open\n\nTap a time."
    end
  end

  defp day_time_keyboard(date, slots) do
    by_hour = Enum.group_by(slots, & &1.start_time)

    time_buttons =
      by_hour
      |> Enum.sort_by(fn {t, _} -> t end, Time)
      |> Enum.map(fn {t, list} ->
        %ExGram.Model.InlineKeyboardButton{
          text: "#{Views.format_time(t)} (#{length(list)})",
          callback_data: "free:t:#{Date.to_iso8601(date)}:#{format_time_url(t)}"
        }
      end)

    rows = Enum.chunk_every(time_buttons, 3)

    nav = [
      %ExGram.Model.InlineKeyboardButton{text: "← Days", callback_data: "free:root"},
      %ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "free:close"}
    ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [nav]}
  end

  defp time_text(date, at, slots) do
    n = length(slots)
    suffix = if n == 1, do: "1 court", else: "#{n} courts"
    "*#{long_label(date)} · #{Views.format_time(at)}* — #{suffix} free.\n\nTap a court to book."
  end

  defp court_keyboard(date, _at, slots) do
    book_buttons =
      Enum.map(slots, fn s ->
        %ExGram.Model.InlineKeyboardButton{
          text: shorten(s.facility_name),
          callback_data: "book:" <> Slot.key(s)
        }
      end)

    rows = Enum.chunk_every(book_buttons, 2)

    nav = [
      %ExGram.Model.InlineKeyboardButton{
        text: "← Times",
        callback_data: "free:d:#{Date.to_iso8601(date)}"
      },
      %ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "free:close"}
    ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [nav]}
  end

  defp menu_row do
    [
      %ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"},
      %ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "free:close"}
    ]
  end

  defp back_to_root do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{text: "← Days", callback_data: "free:root"},
          %ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "free:close"}
        ]
      ]
    }
  end

  ## Plumbing

  defp ensure_courts do
    case Courts.load() do
      {:ok, c} ->
        {:ok, c}

      {:error, :not_yet_discovered} ->
        prefs = Lacuna.Config.load!()

        with session <- Session.current!(),
             {:ok, list} <- API.list_facilities(session) do
          filtered = Courts.filter_by_category(list, prefs.match.category)

          catalog =
            Enum.map(filtered, fn f ->
              %{id: Map.get(f, "facility_id"), name: Map.get(f, "facility_name")}
            end)

          Courts.save(catalog)
          {:ok, catalog}
        end
    end
  end

  defp gather(_session, courts, date) do
    Enum.reduce_while(courts, {:ok, []}, fn court, {:ok, acc} ->
      session = Session.current!()

      case API.facility_availability(session, court.id, date) do
        {:ok, details} ->
          slots = Availability.open_slots(Map.put_new(details, "facility_id", court.id), date)
          {:cont, {:ok, acc ++ [{court, slots}]}}

        {:error, reason} ->
          {:halt, {:error, {court.id, reason}}}
      end
    end)
  end

  defp flatten(by_court),
    do: by_court |> Map.values() |> Enum.flat_map(fn {_, s} -> s end)

  defp edit(message, text, markup) do
    ExGram.edit_message_text(text,
      chat_id: message.chat.id,
      message_id: message.message_id,
      parse_mode: "Markdown",
      reply_markup: markup
    )
  end

  defp short_label(_date, 0), do: "Today"
  defp short_label(_date, 1), do: "Tom"

  defp short_label(date, _) do
    "#{day_short(Date.day_of_week(date))} #{pad(date.day)}"
  end

  defp long_label(date) do
    today = Clock.local_today()
    delta = Date.diff(date, today)

    prefix =
      case delta do
        0 -> "Today"
        1 -> "Tomorrow"
        _ -> "#{day_short(Date.day_of_week(date))} #{pad(date.day)} #{month_short(date.month)}"
      end

    if delta in [0, 1] do
      "#{prefix} · #{pad(date.day)} #{month_short(date.month)}"
    else
      prefix
    end
  end

  defp shorten(name) when is_binary(name) do
    parts = name |> String.split(~r/[\s\-_]+/, trim: true)

    initials =
      parts
      |> Enum.map_join("", fn p ->
        cond do
          p =~ ~r/^\d+$/ -> p
          p == "" -> ""
          true -> String.first(p) |> String.upcase()
        end
      end)

    if String.length(initials) in 2..8, do: initials, else: String.slice(name, 0, 14)
  end

  defp shorten(_), do: "?"

  defp format_time_url(%Time{hour: h, minute: m}), do: "#{pad(h)}-#{pad(m)}"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp trunc_inspect(t), do: t |> inspect() |> String.slice(0, 200)

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
