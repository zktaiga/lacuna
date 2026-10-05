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

  require Logger

  alias Lacuna.{Clock, Slot, Telegram.Views}
  alias Lacuna.Backend.{API, Cache, Courts, Session}

  @lookahead_days 14
  @weekday_names %{
    "mon" => 1,
    "monday" => 1,
    "tue" => 2,
    "tuesday" => 2,
    "wed" => 3,
    "wednesday" => 3,
    "thu" => 4,
    "thursday" => 4,
    "fri" => 5,
    "friday" => 5,
    "sat" => 6,
    "saturday" => 6,
    "sun" => 7,
    "sunday" => 7
  }

  ## Commands

  @spec send_root(integer()) :: :ok
  def send_root(chat_id) do
    text = "*Find slots*\n\nPick a day."
    markup = day_keyboard()

    case ExGram.send_message(chat_id, text, parse_mode: "Markdown", reply_markup: markup) do
      {:ok, _} -> :ok
      other -> Logger.warning("/free send failed: #{inspect(other)}")
    end

    :ok
  end

  def send_query(chat_id, query) do
    case parse_query(query) do
      {:ok, clauses} ->
        slots =
          clauses
          |> Enum.flat_map(fn {date, times} ->
            case fetch_open(date) do
              {:ok, by_court} ->
                flatten(by_court)
                |> Enum.filter(fn slot ->
                  Enum.any?(times, &(Time.compare(slot.start_time, &1) == :eq))
                end)

              {:error, reason} ->
                Logger.warning(
                  "/free query fetch failed for #{Date.to_iso8601(date)}: #{inspect(reason)}"
                )

                []
            end
          end)
          |> Enum.uniq_by(&Slot.key/1)
          |> Enum.sort_by(fn s -> {s.date, s.start_time, s.facility_name} end)

        text = query_text(query, slots)

        if slots == [] do
          ExGram.send_message(chat_id, text,
            parse_mode: "Markdown",
            reply_markup: free_query_nav()
          )
        else
          ExGram.send_message(chat_id, text,
            parse_mode: "Markdown",
            reply_markup: query_keyboard(slots)
          )
        end

      {:error, reason} ->
        ExGram.send_message(
          chat_id,
          "⚠️ Couldn't parse that search: #{reason}\nTry `/free wed 18,19 thu 18,19`.",
          parse_mode: "Markdown",
          reply_markup: free_query_nav()
        )
    end

    :ok
  end

  ## Edits (callback handlers)

  def edit_to_root(message), do: edit_to_root(message, nil)

  def edit_to_root(message, _legacy_session_id) do
    edit(message, "*Find slots*\n\nPick a day.", day_keyboard())
  end

  def replace_expired(message), do: edit_to_root(message)

  def edit_to_day(message, _legacy_session_id, %Date{} = date) do
    case fetch_open(date) do
      {:ok, by_court} ->
        flat = flatten(by_court)
        edit(message, day_text(date, flat), day_time_keyboard(date, flat))

      {:error, reason} ->
        edit(message, "Couldn't fetch: `#{trunc_inspect(reason)}`", back_to_root())
    end
  end

  def edit_to_day(message, %Date{} = date), do: edit_to_day(message, nil, date)

  def edit_to_time(message, _legacy_session_id, %Date{} = date, %Time{} = at) do
    case fetch_open(date) do
      {:ok, by_court} ->
        slots =
          flatten(by_court) |> Enum.filter(fn s -> Time.compare(s.start_time, at) == :eq end)

        edit(message, time_text(date, at, slots), court_keyboard(date, at, slots))

      {:error, reason} ->
        edit(message, "Couldn't fetch: `#{trunc_inspect(reason)}`", back_to_root())
    end
  end

  def edit_to_time(message, %Date{} = date, %Time{} = at),
    do: edit_to_time(message, nil, date, at)

  ## Data

  defp parse_query(query) do
    tokens = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    tokens
    |> Enum.reduce_while({:ok, nil, []}, fn token, {:ok, current_day, acc} ->
      cond do
        Map.has_key?(@weekday_names, token) ->
          {:cont, {:ok, token, acc}}

        current_day && time_list?(token) ->
          {:cont, {:ok, current_day, acc ++ [{current_day, parse_time_list(token)}]}}

        true ->
          {:halt, {:error, "expected weekday followed by times"}}
      end
    end)
    |> case do
      {:ok, _current, []} ->
        {:error, "no day/time pairs found"}

      {:ok, _current, pairs} ->
        clauses =
          pairs
          |> Enum.map(fn {day, times} -> {next_date_for(day), times} end)
          |> Enum.group_by(fn {date, _times} -> date end, fn {_date, times} -> times end)
          |> Enum.map(fn {date, time_lists} ->
            {date, time_lists |> List.flatten() |> Enum.uniq()}
          end)

        {:ok, clauses}

      {:error, _} = err ->
        err
    end
  end

  defp time_list?(token),
    do: String.match?(token, ~r/^\d{1,2}(:\d{2})?(am|pm)?(,\d{1,2}(:\d{2})?(am|pm)?)*$/)

  defp parse_time_list(token), do: token |> String.split(",") |> Enum.map(&parse_query_time!/1)

  defp parse_query_time!(value) do
    value = String.trim(value)

    {raw, suffix} =
      if String.ends_with?(value, "am") or String.ends_with?(value, "pm"),
        do: {String.slice(value, 0..-3//1), String.slice(value, -2, 2)},
        else: {value, nil}

    [hour | rest] = String.split(raw, ":")

    minute =
      rest
      |> List.first()
      |> case do
        nil -> 0
        m -> String.to_integer(m)
      end

    hour = String.to_integer(hour)

    hour =
      case suffix do
        "pm" when hour < 12 -> hour + 12
        "am" when hour == 12 -> 0
        _ -> hour
      end

    Time.new!(hour, minute, 0)
  end

  defp next_date_for(day) do
    target = Map.fetch!(@weekday_names, day)
    today = Clock.local_today()
    delta = rem(target - Date.day_of_week(today) + 7, 7)
    Date.add(today, delta)
  end

  defp query_text(query, []), do: "No slots matched `#{query}`."

  defp query_text(query, slots) do
    body = slots |> Enum.map_join("\n", &Views.render_slot/1)
    "*Matches for* `#{query}`\n\n#{body}" <> Views.booking_notices(slots)
  end

  defp fetch_open(%Date{} = date) do
    key = {:availability_day, date}

    case Cache.get(key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        with {:ok, courts} <- ensure_courts(),
             session <- Session.current!(),
             {:ok, raw} <- gather(session, courts, date) do
          filtered =
            Enum.map(raw, fn {court, slots} ->
              {court, slots |> filter_past(date) |> Enum.sort_by(& &1.start_time, Time)}
            end)

          result = Map.new(filtered, fn {c, s} -> {c.id, {c.name, s}} end)

          Cache.put(
            key,
            result,
            Application.get_env(:lacuna, :availability_cache_ttl_seconds, 180)
          )

          {:ok, result}
        end
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
          callback_data: callback_data("d:#{Date.to_iso8601(date)}")
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
      "*#{long_label(date)}*\n\nChoose a time."
    end
  end

  @doc false
  def time_button_label(time, slots, {:ok, bookings}) do
    count =
      Enum.count(slots, fn slot ->
        not Enum.any?(
          bookings,
          &(Lacuna.Bookings.active?(&1) and Lacuna.Bookings.same_slot?(&1, slot))
        )
      end)

    "#{Views.format_time(time)} (#{count})"
  end

  def time_button_label(time, _slots, _error), do: "#{Views.format_time(time)} (?)"

  defp day_time_keyboard(date, slots) do
    bookings = Lacuna.Bookings.upcoming(cached: true)
    by_hour = Enum.group_by(slots, & &1.start_time)

    time_buttons =
      by_hour
      |> Enum.sort_by(fn {t, _} -> t end, Time)
      |> Enum.map(fn {t, list} ->
        %ExGram.Model.InlineKeyboardButton{
          text: time_button_label(t, list, bookings),
          callback_data: callback_data("t:#{Date.to_iso8601(date)}:#{format_time_url(t)}")
        }
      end)

    rows = Enum.chunk_every(time_buttons, 3)

    nav = [
      %ExGram.Model.InlineKeyboardButton{
        text: "← Days",
        callback_data: callback_data("root")
      },
      %ExGram.Model.InlineKeyboardButton{
        text: "Done",
        callback_data: callback_data("close")
      }
    ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [nav]}
  end

  defp time_text(date, at, slots) do
    end_time =
      case slots do
        [slot | _] -> slot.end_time
        [] -> Time.add(at, 3600)
      end

    "*#{Views.booking_time(date, at, end_time)}*\n\nChoose a court. Nothing is changed on this screen."
  end

  defp court_keyboard(date, _at, slots) do
    bookings = Lacuna.Bookings.upcoming(cached: true)

    book_buttons =
      slots
      |> Enum.sort_by(&Views.court_label(&1.facility_name))
      |> Enum.map(&Views.booking_button(&1, bookings, show_time: false))

    rows = Enum.map(book_buttons, &[&1])

    nav = [
      %ExGram.Model.InlineKeyboardButton{
        text: "← Times",
        callback_data: callback_data("d:#{Date.to_iso8601(date)}")
      },
      %ExGram.Model.InlineKeyboardButton{
        text: "Done",
        callback_data: callback_data("close")
      }
    ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [nav]}
  end

  defp menu_row do
    [
      %ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"},
      %ExGram.Model.InlineKeyboardButton{
        text: "Done",
        callback_data: callback_data("close")
      }
    ]
  end

  defp back_to_root do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{
            text: "← Days",
            callback_data: callback_data("root")
          },
          %ExGram.Model.InlineKeyboardButton{
            text: "Done",
            callback_data: callback_data("close")
          }
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
    owned =
      case Lacuna.Bookings.upcoming(cached: true) do
        {:ok, list} -> list
        _ -> []
      end

    Enum.reduce_while(courts, {:ok, []}, fn court, {:ok, acc} ->
      session = Session.current!()

      case API.facility_availability(session, court.id, date) do
        {:ok, details} ->
          slots =
            Lacuna.Bookings.browsing_slots(
              Map.put_new(details, "facility_id", court.id),
              date,
              owned
            )

          {:cont, {:ok, acc ++ [{court, slots}]}}

        {:error, reason} ->
          {:halt, {:error, {court.id, reason}}}
      end
    end)
  end

  defp flatten(by_court),
    do: by_court |> Map.values() |> Enum.flat_map(fn {_, s} -> s end)

  defp query_keyboard(slots) do
    rows = Views.book_keyboard(slots).inline_keyboard
    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ free_query_nav_rows()}
  end

  defp free_query_nav do
    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: free_query_nav_rows()}
  end

  defp free_query_nav_rows do
    [[%ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}]]
  end

  @doc false
  def callback_data(action), do: "f:#{action}"

  defp edit(message, text, markup) do
    case ExGram.edit_message_text(text,
           chat_id: message.chat.id,
           message_id: message.message_id,
           parse_mode: "Markdown",
           reply_markup: markup
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if message_not_modified?(reason) do
          :ok
        else
          Logger.warning("/free edit failed without fallback send: #{inspect(reason)}")
          :ok
        end

      other ->
        Logger.warning("/free edit returned unexpected response: #{inspect(other)}")
        :ok
    end
  end

  defp message_not_modified?(%ExGram.Error{code: 400, message: message}) when is_binary(message),
    do: String.contains?(message, "message is not modified")

  defp message_not_modified?(_), do: false

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

  defp format_time_url(%Time{hour: h, minute: m}), do: "#{pad(h)}-#{pad(m)}"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

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
