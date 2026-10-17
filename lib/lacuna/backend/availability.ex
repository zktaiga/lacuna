defmodule Lacuna.Backend.Availability do
  @moduledoc """
  Shared, fail-closed parsing of provider availability. Optional legacy occupancy
  fields may be absent, but present malformed fields invalidate the whole cell.
  Any booked overlap, explicit veto or exhausted capacity closes a slot.

  Windowed grids remain readable; mutations support only verified-free fixed
  slots. Overnight intervals are unsupported and rejected rather than wrapped.
  """

  alias Lacuna.Slot

  @doc "Validate availability before using it for reads or destructive preflight."
  @spec validate(term()) :: :ok | {:error, :invalid_availability}
  def validate(details) do
    case decode(details) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Validate the shared response and require a supported, verified-free fixed facility."
  @spec validate_bookable(term()) :: :ok | {:error, atom()}
  def validate_bookable(details) do
    with :ok <- validate(details) do
      cond do
        not fixed?(details) ->
          {:error, :unsupported_booking_mode}

        Map.get(details, "is_chargeable") in [true, 1, "1", "true"] ->
          {:error, :paid_facility_unsupported}

        true ->
          free_price(details)
      end
    end
  end

  @doc "Compute open slots; invalid responses fail closed. Call validate/1 for coverage errors."
  @spec open_slots(term(), Date.t(), keyword()) :: [Slot.t()]
  def open_slots(details, date, opts \\ [])

  def open_slots(details, %Date{} = date, opts) do
    with {:ok, parsed} <- decode(details),
         false <- Date.day_of_week(date) in parsed.blocked,
         {:ok, grid} <- grid(parsed, opts) do
      grid
      |> Enum.reject(fn {{st, en}, id} ->
        Enum.any?(parsed.booked, fn {bs, be} -> st < be and bs < en end) or
          availability_veto?(Map.get(parsed.availability, id)) or
          capacity_veto?(Map.get(parsed.capacity, id))
      end)
      |> Enum.map(&slot(&1, details, date))
    else
      _ -> []
    end
  end

  def open_slots(_, _, _), do: []

  defp decode(details) do
    {:ok, parse_details(details)}
  rescue
    _ -> {:error, :invalid_availability}
  end

  defp parse_details(details) when is_map(details) do
    optional(details, "facility_id", &id!/1, nil)
    optional(details, "is_facility_fixed_slot_based", &boolean!/1, false)
    fixed_grid = optional(details, "fixed_time_slots", &fixed_grid!/1, nil)

    if fixed_grid do
      starts = Enum.map(fixed_grid, fn {{st, _en}, _id} -> st end)
      ensure!(length(Enum.uniq(starts)) == length(starts))
    end

    granularity = optional(details, "booking_hrs", &positive_integer!/1, 1) * 60

    grid =
      if fixed?(details) do
        ensure!(not is_nil(fixed_grid))
        {:fixed, fixed_grid}
      else
        st = clock!(details["start_hour"], Map.get(details, "start_min", 0))
        en = clock!(details["end_hour"], Map.get(details, "end_min", 0))
        ensure!(st < en)
        {:window, st, en, granularity}
      end

    weekdays = optional(details, "week_days", &weekdays!/1, %{})

    %{
      grid: grid,
      booked: optional(details, "booked_slots_on_date", &booked!/1, []),
      availability: optional(details, "slot_availability", &availability!/1, %{}),
      capacity: optional(details, "slots_capacity_details", &capacity!/1, %{}),
      blocked: optional(details, "blocked_week_days", &blocked!(&1, weekdays), [])
    }
  end

  defp fixed?(details), do: details["is_facility_fixed_slot_based"] in [true, 1, "1", "true"]

  defp optional(details, key, parser, default) do
    case Map.fetch(details, key) do
      :error -> default
      {:ok, value} -> parser.(value)
    end
  end

  defp ensure!(true), do: :ok
  defp ensure!(_), do: raise(ArgumentError, "invalid availability")

  defp id!(id) when is_integer(id) and id >= 0, do: Integer.to_string(id)

  defp id!(id) when is_binary(id) and byte_size(id) > 0 do
    ensure!(String.trim(id) == id)
    id
  end

  defp integer!(value) when is_integer(value), do: value

  defp integer!(value) when is_binary(value) do
    {n, ""} = Integer.parse(value)
    n
  end

  defp positive_integer!(value) do
    n = integer!(value)
    ensure!(n > 0)
    n
  end

  defp boolean!(value) when value in [true, 1, "1", "true"], do: true
  defp boolean!(value) when value in [false, 0, "0", "false"], do: false

  defp time!(%Time{microsecond: {0, _}} = t), do: t.hour * 3600 + t.minute * 60 + t.second

  defp time!(value) when is_binary(value) do
    ensure!(Regex.match?(~r/^\d{1,2}:\d{2}(:\d{2})?$/, value))
    [h, m | rest] = String.split(value, ":")
    t = Time.new!(integer!(h), integer!(m), if(rest == [], do: 0, else: integer!(hd(rest))))
    time!(t)
  end

  defp clock!(h, m), do: time!(Time.new!(integer!(h), integer!(m), 0))

  defp interval!(row) when is_map(row) do
    st = time!(Map.fetch!(row, "start_time"))
    duration = positive_integer!(Map.fetch!(row, "duration"))
    en = st + duration * 60
    ensure!(en < 86_400)
    {st, en}
  end

  defp booked!(rows) when is_list(rows), do: Enum.map(rows, &interval!/1)

  defp range!(range) when is_binary(range) do
    [a, b] = String.split(range, ~r/\s*-\s*/, parts: 2)
    st = time!(String.trim(a))
    en = time!(String.trim(b))
    ensure!(st < en)
    {st, en}
  end

  defp fixed_grid!(slots) when is_map(slots) do
    keyed!(slots, fn key, range -> {id!(key), range!(range)} end)
    |> Enum.map(fn {id, times} -> {times, id} end)
  end

  defp fixed_grid!(slots) when is_list(slots) do
    keyed!(slots, fn row ->
      id = row_id!(row, "id")
      {id, interval!(row)}
    end)
    |> Enum.map(fn {id, times} -> {times, id} end)
  end

  defp row_id!(row, primary) when is_map(row) do
    id = id!(Map.get(row, primary, row["facility_time_slot_id"]))

    if Map.has_key?(row, "facility_time_slot_id"),
      do: ensure!(id!(row["facility_time_slot_id"]) == id)

    id
  end

  # Canonicalize IDs before checking duplicates, never silently overwrite vetoes.
  defp keyed!(entries, parser) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      {id, value} =
        if is_tuple(entry), do: parser.(elem(entry, 0), elem(entry, 1)), else: parser.(entry)

      ensure!(not Map.has_key?(acc, id) or Map.fetch!(acc, id) == value)
      Map.put(acc, id, value)
    end)
  end

  defp availability!(entries) when is_map(entries) do
    keyed!(entries, fn key, entry ->
      id = id!(key)
      {id, availability_entry!(entry, id)}
    end)
  end

  defp availability!(entries) when is_list(entries) do
    keyed!(entries, fn row ->
      id = row_id!(row, "facility_time_slot_id")
      {id, availability_entry!(row, id)}
    end)
  end

  defp availability_entry!(value, _) when is_boolean(value), do: %{"is_available" => value}

  defp availability_entry!(row, id) when is_map(row) do
    if Map.has_key?(row, "facility_time_slot_id"),
      do: ensure!(id!(row["facility_time_slot_id"]) == id)

    ensure!(Map.has_key?(row, "is_available") or Map.has_key?(row, "slots"))

    Enum.reduce([{"is_available", &boolean!/1}, {"slots", &integer!/1}], %{}, fn {key, parser},
                                                                                 acc ->
      case Map.fetch(row, key) do
        :error -> acc
        {:ok, value} -> Map.put(acc, key, parser.(value))
      end
    end)
  end

  defp availability_veto?(nil), do: false

  defp availability_veto?(row),
    do: row["is_available"] == false or (Map.has_key?(row, "slots") and row["slots"] <= 0)

  # The live legacy endpoint sends [] when no capacity metadata exists. Nonempty
  # lists have no established contract and must not become permission to cancel.
  defp capacity!([]), do: %{}

  defp capacity!(entries) when is_map(entries) do
    keyed!(entries, fn key, row ->
      id = id!(key)
      ensure!(is_map(row))
      capacity = Map.fetch!(row, "capacity")
      available = Map.fetch!(row, "available")
      ensure!(is_integer(capacity) and capacity >= 0 and is_integer(available))
      optional(row, "slots", fn slots -> ensure!(is_binary(slots)) end, nil)
      optional(row, "booked", fn booked -> ensure!(is_integer(booked) and booked >= 0) end, nil)
      optional(row, "facility_time_slot_id", &id!/1, nil)
      {id, Map.take(row, ["capacity", "available", "slots", "booked"])}
    end)
  end

  defp capacity_veto?(nil), do: false
  defp capacity_veto?(row), do: row["capacity"] > 0 and row["available"] <= 0

  defp weekdays!(rows) when is_list(rows) do
    keyed!(rows, fn row ->
      index = Map.fetch!(row, "week_day_index")
      ensure!(is_integer(index) and index >= 0)
      day = weekday!(Map.fetch!(row, "week_day_key"))
      title = weekday!(Map.fetch!(row, "week_day_title"))
      ensure!(day == title)
      {Integer.to_string(index), day}
    end)
  end

  defp blocked!(rows, weekdays) when is_list(rows),
    do: Enum.map(rows, &blocked_day!(&1, weekdays))

  defp blocked_day!(%{"day" => day}, weekdays), do: blocked_day!(day, weekdays)

  defp blocked_day!(day, weekdays) when is_binary(day) do
    case Integer.parse(day) do
      {_, ""} -> Map.fetch!(weekdays, day)
      _ -> weekday!(day)
    end
  end

  defp weekday!(day) when is_binary(day) do
    case String.downcase(day) do
      d when d in ["mon", "monday"] -> 1
      d when d in ["tue", "tuesday"] -> 2
      d when d in ["wed", "wednesday"] -> 3
      d when d in ["thu", "thursday"] -> 4
      d when d in ["fri", "friday"] -> 5
      d when d in ["sat", "saturday"] -> 6
      d when d in ["sun", "sunday"] -> 7
    end
  end

  defp grid(%{grid: {:fixed, entries}}, _), do: {:ok, entries}

  defp grid(%{grid: {:window, st, en, default}}, opts) do
    minutes = Keyword.get(opts, :granularity_minutes, default)

    if is_integer(minutes) and minutes > 0 do
      seconds = minutes * 60
      count = div(en - st, seconds)

      entries =
        if count == 0 do
          []
        else
          for i <- 0..(count - 1), do: {{st + i * seconds, st + (i + 1) * seconds}, nil}
        end

      {:ok, entries}
    else
      {:error, :invalid_availability}
    end
  end

  defp free_price(details) do
    chargeable = Map.fetch(details, "is_chargeable")
    price = Map.fetch(details, "facility_rate")

    cond do
      chargeable != :error and elem(chargeable, 1) not in [false, 0, "0", "false"] ->
        {:error, :unknown_facility_price}

      price == :error and chargeable != :error ->
        :ok

      price != :error and parse_number(elem(price, 1)) == 0 ->
        :ok

      price != :error and is_number(parse_number(elem(price, 1))) and
          parse_number(elem(price, 1)) > 0 ->
        {:error, :paid_facility_unsupported}

      true ->
        {:error, :unknown_facility_price}
    end
  end

  defp slot({{st, en}, slot_id}, details, date) do
    name = Map.get(details, "facility_name", "")

    %Slot{
      facility_id: Map.get(details, "facility_id", name),
      facility_name: name,
      date: date,
      start_time: Time.add(~T[00:00:00], st, :second),
      end_time: Time.add(~T[00:00:00], en, :second),
      duration_minutes: div(en - st, 60),
      rate: parse_number(details["facility_rate"]),
      rate_type: details["rate_type"],
      slot_id: slot_id,
      fee_aed:
        if(free_price(details) == :ok, do: 0, else: parse_number(details["facility_rate"]) || 0)
    }
  end

  defp parse_number(n) when is_number(n), do: n

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_number(_), do: nil
end
