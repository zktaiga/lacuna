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

        case API.make_booking(session, fields) do
          {:ok, response} ->
            Logger.info("Booking response: #{inspect(response, limit: :infinity)}")
            confirm_booking(session, slot, response)

          {:error, _} = err ->
            err
        end
    end
  end

  defp maybe_put_slot_id(fields, %Slot{slot_id: nil}), do: fields
  defp maybe_put_slot_id(fields, %Slot{slot_id: ""}), do: fields

  defp maybe_put_slot_id(fields, %Slot{slot_id: slot_id}),
    do: Map.put(fields, "facility_time_slot_id", to_string(slot_id))

  defp confirm_booking(session, %Slot{} = slot, response) do
    case find_confirmed_booking(session, slot, 3) do
      {:ok, booking} ->
        Cache.delete_prefix(:availability_day)
        Cache.delete(:my_bookings)
        {:ok, %{slot: slot, response: response, booking: booking}}

      {:error, reason} ->
        {:error, {reason, response}}
    end
  end

  defp find_confirmed_booking(session, slot, attempts_left) do
    with {:ok, data} <- API.my_bookings(session) do
      data
      |> upcoming_bookings()
      |> Enum.find(&matches_slot?(&1, slot))
      |> case do
        nil when attempts_left > 1 ->
          Process.sleep(500)
          find_confirmed_booking(session, slot, attempts_left - 1)

        nil ->
          {:error, :booking_not_confirmed}

        booking ->
          {:ok, booking}
      end
    end
  end

  defp upcoming_bookings(data) do
    data
    |> Map.get("my_bookings", %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&upcoming?/1)
  end

  defp upcoming?(booking) do
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

  defp matches_slot?(booking, %Slot{} = slot) do
    booking_facility_matches?(booking, slot) and
      booking_date_matches?(booking, slot.date) and
      booking_time_matches?(booking, slot.start_time)
  end

  defp booking_facility_matches?(booking, slot) do
    Map.get(booking, "facility_id") == slot.facility_id or
      Map.get(booking, "facility_name") == slot.facility_name
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

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp normalize_date(_), do: nil

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
    session = Session.current!()

    case API.cancel_booking(session, booking_id) do
      {:ok, _} ->
        Cache.delete_prefix(:availability_day)
        Cache.delete(:my_bookings)
        :ok

      {:error, _} = err ->
        err
    end
  end
end
