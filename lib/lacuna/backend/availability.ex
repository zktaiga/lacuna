defmodule Lacuna.Backend.Availability do
  @moduledoc """
  Pure functions that turn an availability response (per facility, per
  date) into a list of `%Lacuna.Slot{}` representing the OPEN slots.

  Two formats the upstream uses:

    * **fixed_time_slots**: a precomputed list of `{start_time, duration}`
      pairs the facility offers. We subtract `booked_slots_on_date`.
    * **time-window**: `start_hour:start_min – end_hour:end_min` with a
      `booking_hrs` granularity. We enumerate the grid and subtract
      booked slots.

  Returns `[]` for blocked weekdays. Both formats handled.
  """

  alias Lacuna.Slot
  require Logger

  @doc "Compute open slots for a facility on a given date from the upstream availability map."
  @spec open_slots(map(), Date.t(), keyword()) :: [Slot.t()]
  def open_slots(%{} = details, %Date{} = date, opts \\ []) do
    if blocked?(details, date) do
      []
    else
      booked = parse_booked(details)
      grid = grid(details, date, opts) |> Enum.reject(&overlaps_any?(elem(&1, 0), booked))
      Enum.map(grid, &slot(&1, details, date))
    end
  end

  defp blocked?(%{"blocked_week_days" => blocked}, %Date{} = date) when is_list(blocked) do
    weekday = day_short(Date.day_of_week(date))
    Enum.any?(blocked, fn b -> match_weekday?(b, weekday) end)
  end

  defp blocked?(_, _), do: false

  defp parse_booked(%{"booked_slots_on_date" => list}) when is_list(list) do
    Enum.map(list, fn b ->
      st = parse_time(Map.get(b, "start_time"))
      duration = duration_minutes(b)
      en = Time.add(st, duration * 60, :second)
      {st, en}
    end)
  end

  defp parse_booked(_), do: []

  defp duration_minutes(%{"duration" => d}) when is_integer(d), do: d
  defp duration_minutes(%{"duration" => d}) when is_binary(d), do: String.to_integer(d)
  defp duration_minutes(_), do: 60

  # The upstream serialises `fixed_time_slots` as a map keyed by slot id
  # (e.g. `%{"369" => "18:00 - 19:00"}`) when `is_facility_fixed_slot_based`
  # is true/"1". Each grid entry is `{ {start_time, end_time}, slot_id }`.
  defp grid(%{"is_facility_fixed_slot_based" => v, "fixed_time_slots" => slots}, _date, _opts)
       when v in [true, "1"] and is_map(slots) do
    Enum.map(slots, fn {slot_id, range} ->
      {st, en} = parse_range(range)
      {{st, en}, slot_id}
    end)
  end

  # Older shape: list of {start_time, duration} pairs.
  defp grid(%{"is_facility_fixed_slot_based" => v, "fixed_time_slots" => slots}, _date, _opts)
       when v in [true, "1"] and is_list(slots) do
    Enum.map(slots, fn s ->
      st = parse_time(Map.get(s, "start_time"))
      duration = duration_minutes(s)

      {{st, Time.add(st, duration * 60, :second)},
       Map.get(s, "id") || Map.get(s, "facility_time_slot_id")}
    end)
  end

  defp grid(details, _date, opts) do
    granularity = Keyword.get(opts, :granularity_minutes, default_granularity(details))
    start_t = build_time(details["start_hour"], details["start_min"])
    end_t = build_time(details["end_hour"], details["end_min"])
    enumerate(start_t, end_t, granularity) |> Enum.map(fn pair -> {pair, nil} end)
  end

  defp parse_range(s) when is_binary(s) do
    case String.split(s, ~r/\s*-\s*/, parts: 2) do
      [a, b] -> {parse_time(a), parse_time(b)}
      [a] -> {parse_time(a), parse_time(a)}
    end
  end

  defp default_granularity(details) do
    case details["booking_hrs"] do
      n when is_integer(n) and n > 0 -> n * 60
      n when is_binary(n) -> max(String.to_integer(n) * 60, 30)
      _ -> 60
    end
  end

  defp enumerate(%Time{} = st, %Time{} = en, minutes) do
    cond do
      Time.compare(st, en) in [:gt, :eq] ->
        []

      true ->
        next = Time.add(st, minutes * 60, :second)

        if Time.compare(next, en) == :gt,
          do: [],
          else: [{st, next} | enumerate(next, en, minutes)]
    end
  end

  defp slot({{st, en}, slot_id}, details, %Date{} = date) do
    facility_name = Map.get(details, "facility_name", "")

    %Slot{
      facility_id: Map.get(details, "facility_id", facility_name),
      facility_name: facility_name,
      date: date,
      start_time: st,
      end_time: en,
      duration_minutes: div(Time.diff(en, st, :second), 60),
      rate: parse_number(Map.get(details, "facility_rate")),
      rate_type: Map.get(details, "rate_type"),
      slot_id: slot_id,
      fee_aed: parse_number(Map.get(details, "facility_rate")) || 0
    }
  end

  defp overlaps_any?({st, en}, list),
    do:
      Enum.any?(list, fn {bs, be} ->
        Time.compare(st, be) == :lt and Time.compare(bs, en) == :lt
      end)

  defp build_time(h, m) when is_integer(h) and is_integer(m), do: Time.new!(h, m, 0)
  defp build_time(h, m) when is_binary(h), do: build_time(String.to_integer(h), m || 0)
  defp build_time(h, m) when is_binary(m), do: build_time(h, String.to_integer(m))
  defp build_time(h, _) when is_integer(h), do: Time.new!(h, 0, 0)

  defp parse_time(nil), do: ~T[00:00:00]
  defp parse_time(%Time{} = t), do: t

  defp parse_time(s) when is_binary(s) do
    case Time.from_iso8601(s) do
      {:ok, t} -> t
      {:error, _} -> parse_time_loose(s)
    end
  end

  defp parse_time_loose(s) do
    case String.split(s, ":") do
      [h, m, _ | _] -> Time.new!(String.to_integer(h), String.to_integer(m), 0)
      [h, m] -> Time.new!(String.to_integer(h), String.to_integer(m), 0)
      [h] -> Time.new!(String.to_integer(h), 0, 0)
      _ -> ~T[00:00:00]
    end
  end

  defp parse_number(n) when is_number(n), do: n

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_number(_), do: nil

  defp day_short(1), do: "Mon"
  defp day_short(2), do: "Tue"
  defp day_short(3), do: "Wed"
  defp day_short(4), do: "Thu"
  defp day_short(5), do: "Fri"
  defp day_short(6), do: "Sat"
  defp day_short(7), do: "Sun"

  defp match_weekday?(%{"day" => d}, target), do: weekday_eq?(d, target)
  defp match_weekday?(d, target) when is_binary(d), do: weekday_eq?(d, target)
  defp match_weekday?(_, _), do: false

  defp weekday_eq?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.slice(a, 0, 3)) == String.downcase(String.slice(b, 0, 3))

  defp weekday_eq?(_, _), do: false
end
