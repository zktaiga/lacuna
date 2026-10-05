defmodule Lacuna.Plugins.DefaultBooker do
  @moduledoc """
  Calls the upstream make_booking endpoint for a given Slot.

  Uses the booking form sent by the current Android client for fixed-slot
  facilities. The important details are `enc_ru_id` (not the login user id),
  `booking_date` in `DD/MM/YYYY`, and `facility_time_slot_id`. Refusing to
  book anything with a fee above `[booking].max_fee_aed` is a hard guardrail.
  """

  @behaviour Lacuna.Behaviours.Booker

  alias Lacuna.{Config, Slot}
  alias Lacuna.Backend.{API, Cache, Session}

  require Logger

  @impl true
  def book(%Slot{} = slot, _ctx) do
    prefs = Config.load!()

    cond do
      slot.fee_aed > prefs.booking.max_fee_aed ->
        {:error, {:fee_above_limit, slot.fee_aed, prefs.booking.max_fee_aed}}

      true ->
        session = Session.current!()

        fields =
          %{
            "facility_id" => slot.facility_id,
            "booking_frequency" => "One Time",
            "booking_date" => API.format_date(slot.date),
            "enc_ru_id" => session.ru_id || "",
            "description" => "",
            "booking_type" => "0",
            "is_moderated" => "false"
          }
          |> maybe_put_slot_id(slot)

        before_booking = API.my_bookings(session)

        case API.make_booking(session, fields) do
          {:ok, response} ->
            Logger.info("Booking response: #{inspect(response, limit: :infinity)}")
            confirm_booking(session, slot, response, before_booking)

          {:error, _} = err ->
            err
        end
    end
  end

  defp maybe_put_slot_id(fields, %Slot{slot_id: nil}), do: fields
  defp maybe_put_slot_id(fields, %Slot{slot_id: ""}), do: fields

  defp maybe_put_slot_id(fields, %Slot{slot_id: slot_id}),
    do: Map.put(fields, "facility_time_slot_id", to_string(slot_id))

  defp confirm_booking(session, %Slot{} = slot, response, before_booking) do
    booking_id = response_booking_id(response)

    case find_confirmed_booking(session, slot, booking_id, before_booking, 3) do
      {:ok, booking} ->
        Cache.delete_prefix(:availability_day)
        Cache.delete(:my_bookings)
        {:ok, %{slot: slot, response: response, booking: booking}}

      {:error, _reason} ->
        {:error, {:booking_not_confirmed, response}}
    end
  end

  defp find_confirmed_booking(session, slot, booking_id, before_booking, attempts_left) do
    booking =
      case API.my_bookings(session) do
        {:ok, data} ->
          data
          |> upcoming_bookings()
          |> Enum.find(&confirms_creation?(&1, slot, booking_id, before_booking))

        _ ->
          nil
      end

    cond do
      booking ->
        {:ok, booking}

      attempts_left > 1 ->
        Process.sleep(500)
        find_confirmed_booking(session, slot, booking_id, before_booking, attempts_left - 1)

      true ->
        {:error, :booking_not_confirmed}
    end
  end

  defp confirms_creation?(booking, _slot, booking_id, {:ok, %{"my_bookings" => groups}})
       when not is_nil(booking_id) and is_map(groups) do
    existing = groups |> Map.values() |> List.flatten()

    Enum.all?(Map.values(groups), &is_list/1) and Enum.all?(existing, &is_map/1) and
      booking_id_matches?(booking, booking_id) and
      not Enum.any?(existing, &booking_id_matches?(&1, booking_id))
  end

  defp confirms_creation?(booking, slot, nil, {:ok, %{"my_bookings" => groups}})
       when is_map(groups) do
    id = normalize_id(booking["booking_id"])
    existing = groups |> Map.values() |> List.flatten()

    Enum.all?(Map.values(groups), &is_list/1) and Enum.all?(existing, &is_map/1) and
      id != nil and matches_slot?(booking, slot) and
      not Enum.any?(existing, &booking_id_matches?(&1, id))
  end

  defp confirms_creation?(_, _, _, _), do: false

  defp past_booking?(booking) do
    now = Lacuna.Clock.local_now()
    today = NaiveDateTime.to_date(now)

    case booking |> first_present(["start_date", "booking_date", "date"]) |> normalize_date() do
      %Date{} = date ->
        end_time =
          booking
          |> first_present(["end_time", "booking_end_time", "to_time"])
          |> normalize_time()

        Date.compare(date, today) == :lt or
          (date == today and end_time != nil and
             Time.compare(end_time, NaiveDateTime.to_time(now)) != :gt)

      _ ->
        false
    end
  end

  defp upcoming_bookings(%{"my_bookings" => groups}) when is_map(groups) do
    groups |> Map.values() |> List.flatten() |> Enum.filter(&(is_map(&1) and upcoming?(&1)))
  end

  defp upcoming_bookings(_), do: []

  defp upcoming?(booking) do
    Map.get(booking, "type") == "upcoming_bookings" and
      booking_status(booking) not in ["cancelled", "canceled", "rejected", "failed"] and
      not past_booking?(booking)
  end

  defp response_booking_id(%{} = response), do: normalize_id(Map.get(response, "booking_id"))
  defp response_booking_id(_), do: nil

  defp booking_id_matches?(_booking, nil), do: false

  defp booking_id_matches?(booking, booking_id) do
    normalize_id(Map.get(booking, "booking_id")) == booking_id
  end

  defp normalize_id(nil), do: nil

  defp normalize_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp booking_status(booking) do
    booking
    |> Map.get("status", "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp matches_slot?(booking, %Slot{} = slot) do
    booking_facility_matches?(booking, slot) and
      booking_date_matches?(booking, slot.date) and
      booking_time_matches?(booking, slot.start_time) and
      booking_end_matches?(booking, slot.end_time) and
      booking_slot_id_matches?(booking, slot.slot_id)
  end

  defp booking_facility_matches?(booking, slot) do
    case normalize_id(booking["facility_id"]) do
      nil -> booking["facility_name"] == slot.facility_name
      id -> id == normalize_id(slot.facility_id)
    end
  end

  defp booking_slot_id_matches?(booking, slot_id) do
    case normalize_id(first_present(booking, ["facility_time_slot_id", "slot_id"])) do
      nil -> true
      id -> id == normalize_id(slot_id)
    end
  end

  defp booking_end_matches?(booking, time) do
    case booking
         |> first_present(["end_time", "booking_end_time", "to_time"])
         |> normalize_time() do
      nil -> false
      end_time -> Time.compare(end_time, time) == :eq
    end
  end

  defp booking_date_matches?(booking, date) do
    booking
    |> first_present(["start_date", "booking_date", "date"])
    |> normalize_date()
    |> Kernel.==(date)
  end

  defp booking_time_matches?(booking, time) do
    booking
    |> first_present(["start_time", "booking_start_time", "from_time"])
    |> normalize_time()
    |> case do
      nil -> false
      booking_time -> Time.compare(booking_time, time) == :eq
    end
  end

  defp first_present(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp normalize_date(%Date{} = date), do: date

  defp normalize_date(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        date

      Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, value) ->
        [day, month, year] = String.split(value, "/")
        Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      Regex.match?(~r/^\d{1,2}-[A-Za-z]{3}-\d{4}$/, value) ->
        [day, month, year] = String.split(value, "-")
        Date.new!(String.to_integer(year), month_number!(month), String.to_integer(day))

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp normalize_date(_), do: nil

  defp month_number!(month) do
    case String.downcase(month) do
      "jan" -> 1
      "feb" -> 2
      "mar" -> 3
      "apr" -> 4
      "may" -> 5
      "jun" -> 6
      "jul" -> 7
      "aug" -> 8
      "sep" -> 9
      "oct" -> 10
      "nov" -> 11
      "dec" -> 12
    end
  end

  defp normalize_time(%Time{} = time), do: Time.truncate(time, :second)

  defp normalize_time(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 8)
    |> pad_time_seconds()
    |> Time.from_iso8601()
    |> case do
      {:ok, time} -> Time.truncate(time, :second)
      {:error, _} -> nil
    end
  end

  defp normalize_time(_), do: nil

  defp pad_time_seconds(<<hour_minute::binary-size(5)>>), do: hour_minute <> ":00"
  defp pad_time_seconds(value), do: value

  @impl true
  def cancel(booking_id, _ctx) do
    case Lacuna.Bookings.cancel(booking_id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
