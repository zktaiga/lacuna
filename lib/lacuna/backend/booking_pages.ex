defmodule Lacuna.Backend.BookingPages do
  @moduledoc "Collect the complete upcoming inventory without traversing unrelated past history."

  @page_limit 50

  def collect(fetch_page) when is_function(fetch_page, 1) do
    collect(fetch_page, %{"upcoming_offset" => 0, "past_offset" => 0}, %{}, %{}, @page_limit)
  end

  defp collect(_fetch, _offsets, _groups, _seen, 0),
    do: {:error, :incomplete_bookings}

  defp collect(fetch, offsets, groups, seen, remaining) do
    with {:ok, data} <- fetch.(offsets),
         {:ok, page_groups, next} <- page(data),
         {:ok, merged, seen} <- merge_groups(groups, page_groups, seen) do
      cond do
        next["upcoming_offset"] == -1 ->
          groups = Map.new(merged, fn {key, rows} -> {key, Enum.reverse(rows)} end)
          {:ok, Map.put(data, "my_bookings", groups)}

        next["upcoming_offset"] > offsets["upcoming_offset"] ->
          collect(fetch, next, merged, seen, remaining - 1)

        true ->
          {:error, :incomplete_bookings}
      end
    end
  end

  defp page(%{"my_bookings" => groups, "offset_details" => offsets})
       when is_map(groups) and is_map(offsets) do
    with {:ok, upcoming} <- offset(offsets["upcoming_offset"]),
         {:ok, past} <- offset(offsets["past_offset"]) do
      if Enum.all?(groups, fn {_key, rows} ->
           is_list(rows) and Enum.all?(rows, &valid_booking?/1)
         end) do
        {:ok, groups,
         offsets |> Map.put("upcoming_offset", upcoming) |> Map.put("past_offset", past)}
      else
        {:error, :invalid_bookings}
      end
    end
  end

  defp page(%{"my_bookings" => groups}) when is_map(groups),
    do: {:error, :incomplete_bookings}

  defp page(_), do: {:error, :invalid_bookings}

  defp offset(value) when is_integer(value) and value >= -1, do: {:ok, value}

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= -1 -> {:ok, number}
      _ -> {:error, :incomplete_bookings}
    end
  end

  defp offset(_), do: {:error, :incomplete_bookings}

  defp merge_groups(groups, page, seen) do
    Enum.reduce_while(page, {:ok, groups, seen}, fn {key, rows}, {:ok, acc, ids} ->
      case merge_rows(rows, Map.get(acc, key, []), ids) do
        {:ok, merged, ids} -> {:cont, {:ok, Map.put(acc, key, merged), ids}}
        error -> {:halt, error}
      end
    end)
  end

  defp merge_rows(rows, accumulated, seen) do
    Enum.reduce_while(rows, {:ok, accumulated, seen}, fn row, {:ok, acc, ids} ->
      case booking_id(row["booking_id"]) do
        nil ->
          {:halt, {:error, :invalid_bookings}}

        id ->
          case Map.fetch(ids, id) do
            :error -> {:cont, {:ok, [row | acc], Map.put(ids, id, row)}}
            {:ok, ^row} -> {:cont, {:ok, acc, ids}}
            {:ok, _} -> {:halt, {:error, :inconsistent_bookings}}
          end
      end
    end)
  end

  defp valid_booking?(row) when is_map(row) do
    row["type"] in ["upcoming_bookings", "past_bookings"] and
      booking_id(row["booking_id"]) != nil and booking_id(row["facility_id"]) != nil and
      valid_status?(row["status"]) and valid_interval?(row)
  end

  defp valid_booking?(_), do: false

  # Unknown approval statuses must remain visible to the conservative active-booking guard.
  defp valid_status?(status) when is_binary(status),
    do: String.valid?(status) and String.trim(status) != ""

  defp valid_status?(_), do: false

  defp valid_interval?(row) do
    with {:ok, _date} <- parse_date(row["start_date"] || row["booking_date"] || row["date"]),
         {:ok, start_time} <-
           parse_time(row["start_time"] || row["booking_start_time"] || row["from_time"]),
         {:ok, end_time} <-
           parse_time(row["end_time"] || row["booking_end_time"] || row["to_time"]) do
      Time.compare(start_time, end_time) == :lt
    else
      _ -> false
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      _ ->
        case Regex.run(~r/\A([0-9]{1,2})[-\/]([0-9]{1,2}|[A-Za-z]{3})[-\/]([0-9]{4})\z/, value) do
          [_, day, month, year] ->
            Date.new(String.to_integer(year), month_number(month), String.to_integer(day))

          _ ->
            :error
        end
    end
  end

  defp parse_date(_), do: :error

  defp month_number(month) do
    case Integer.parse(month) do
      {number, ""} ->
        number

      _ ->
        (Enum.find_index(
           ~w(jan feb mar apr may jun jul aug sep oct nov dec),
           &(&1 == String.downcase(month))
         ) || -1) + 1
    end
  end

  defp parse_time(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\z/, value) do
      Time.from_iso8601(if byte_size(value) == 5, do: value <> ":00", else: value)
    else
      :error
    end
  end

  defp parse_time(_), do: :error

  defp booking_id(value) when is_integer(value), do: Integer.to_string(value)

  defp booking_id(value) when is_binary(value) do
    if String.valid?(value) and value != "" and String.trim(value) == value,
      do: value,
      else: nil
  end

  defp booking_id(_), do: nil
end
