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
            Cache.delete_prefix(:availability_day)
            Cache.delete(:my_bookings)
            {:ok, %{slot: slot, response: response}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp maybe_put_slot_id(fields, %Slot{slot_id: nil}), do: fields
  defp maybe_put_slot_id(fields, %Slot{slot_id: ""}), do: fields

  defp maybe_put_slot_id(fields, %Slot{slot_id: slot_id}),
    do: Map.put(fields, "facility_time_slot_id", to_string(slot_id))

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
