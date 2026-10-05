defmodule Lacuna.Bookings do
  @moduledoc "Shared booking eligibility and serialized, explicitly requested replacements."

  alias Lacuna.{Clock, Config, Slot}
  alias Lacuna.Backend.{API, Availability, Cache, Session}

  def upcoming(opts \\ []) do
    if Keyword.get(opts, :cached, false) do
      case Cache.get(:my_bookings) do
        {:ok, bookings} -> {:ok, bookings}
        :miss -> fetch_upcoming(opts)
      end
    else
      fetch_upcoming(opts)
    end
  end

  defp fetch_upcoming(opts) do
    with {:ok, data} <- api(opts).my_bookings(session(opts)),
         {:ok, records} <- booking_records(data) do
      bookings = Enum.filter(records, &active?/1)

      if Keyword.get(opts, :cached, false) do
        Cache.put(
          :my_bookings,
          bookings,
          Application.get_env(:lacuna, :bookings_cache_ttl_seconds, 30)
        )
      end

      {:ok, bookings}
    end
  end

  defp booking_records(%{"my_bookings" => groups}) when is_map(groups) do
    lists = Map.values(groups)

    if Enum.all?(lists, &is_list/1) and Enum.all?(List.flatten(lists), &is_map/1),
      do: {:ok, List.flatten(lists)},
      else: {:error, :invalid_bookings}
  end

  defp booking_records(_), do: {:error, :invalid_bookings}

  def eligibility(%Slot{} = slot, bookings) when is_list(bookings) do
    same_court = Enum.filter(bookings, &(active?(&1) and same_court?(&1, slot)))

    case Enum.find(same_court, &same_slot?(&1, slot)) do
      nil ->
        case same_court do
          [] -> :bookable
          [booking] -> {:replacement_required, booking}
          _ -> {:blocked, :multiple_existing_bookings}
        end

      booking ->
        {:already_booked, booking}
    end
  end

  def check(%Slot{} = slot, opts \\ []) do
    with {:ok, bookings} <- upcoming(opts), do: eligibility(slot, bookings)
  end

  def book(%Slot{} = slot, ctx \\ %{}, opts \\ []) do
    serialized(fn ->
      case check(slot, opts) do
        :bookable ->
          with {:ok, fresh} <- refresh_slot(slot, opts), do: run_booker(fresh, ctx, opts)

        {:error, _} = error ->
          error

        other ->
          {:error, other}
      end
    end)
  end

  def replace(%Slot{} = slot, booking_id, ctx \\ %{}, opts \\ []) do
    serialized(fn ->
      with {:ok, bookings} <- upcoming(opts),
           {:ok, old} <- replacement_booking(slot, booking_id, bookings),
           :ok <- unchanged_booking(old, opts),
           {:ok, fresh} <- refresh_slot(slot, opts),
           :ok <- check_fee(fresh),
           {:ok, _} <- api(opts).cancel_booking(session(opts), old["booking_id"]) do
        invalidate()

        case safely_run_replacement(fresh, ctx, opts) do
          {:ok, result} -> {:ok, Map.put(result, :replaced_booking, old)}
          {:error, reason} -> {:error, {:replacement_failed, :old_booking_cancelled, reason}}
        end
      end
    end)
  end

  def cancel(booking_id, opts \\ []) do
    serialized(fn ->
      case api(opts).cancel_booking(session(opts), booking_id) do
        {:ok, _} = result ->
          invalidate()
          result

        error ->
          error
      end
    end)
  end

  def refresh_slot(%Slot{} = slot, opts \\ []) do
    with :ok <- future_slot(slot),
         {:ok, details} <-
           api(opts).facility_availability(session(opts), slot.facility_id, slot.date) do
      details
      |> Map.put_new("facility_id", slot.facility_id)
      |> Availability.open_slots(slot.date)
      |> Enum.find(
        &(Time.compare(&1.start_time, slot.start_time) == :eq and
            Time.compare(&1.end_time, slot.end_time) == :eq)
      )
      |> case do
        nil -> {:error, :slot_no_longer_open}
        fresh -> {:ok, fresh}
      end
    end
  end

  def snapshot(booking),
    do:
      {to_string(booking["facility_id"] || booking["facility_name"]),
       parse_date(booking["start_date"] || booking["booking_date"] || booking["date"]),
       parse_time(booking["start_time"] || booking["booking_start_time"] || booking["from_time"]),
       parse_time(booking["end_time"] || booking["booking_end_time"] || booking["to_time"])}

  defp unchanged_booking(booking, opts) do
    case Keyword.fetch(opts, :expected_booking) do
      {:ok, expected} ->
        if snapshot(booking) == expected, do: :ok, else: {:error, :existing_booking_changed}

      :error ->
        :ok
    end
  end

  def browsing_slots(details, date, bookings) do
    open = Availability.open_slots(details, date)

    grid =
      details
      |> Map.delete("booked_slots_on_date")
      |> Map.delete("slot_availability")
      |> Availability.open_slots(date)

    owned =
      Enum.filter(grid, fn slot ->
        Enum.any?(bookings, &(active?(&1) and same_slot?(&1, slot)))
      end)

    Enum.uniq_by(open ++ owned, &Slot.key/1) |> Enum.sort_by(& &1.start_time)
  end

  defp replacement_booking(slot, id, bookings) do
    case eligibility(slot, bookings) do
      {:replacement_required, booking} ->
        if to_string(booking["booking_id"]) == to_string(id),
          do: {:ok, booking},
          else: {:error, :existing_booking_changed}

      _ ->
        {:error, :existing_booking_changed}
    end
  end

  defp safely_run_replacement(slot, ctx, opts) do
    run_booker(slot, Map.put(ctx, :replacement, true), opts)
  rescue
    _ -> {:error, :replacement_booking_exception}
  catch
    :exit, _ -> {:error, :replacement_booking_exception}
  end

  defp run_booker(slot, ctx, opts) do
    booker =
      Keyword.get_lazy(opts, :booker, fn ->
        Config.load!().plugins.booker || Lacuna.Plugins.DefaultBooker
      end)

    case apply(booker, :book, [slot, ctx]) do
      {:error, reason} ->
        if active_booking_limit?(reason),
          do: {:error, {:household_booking_limit, reason}},
          else: {:error, reason}

      result ->
        result
    end
  end

  def active_booking_limit?(reason),
    do:
      inspect(reason) =~ "Residents are permitted to have 1 active bookings" or
        match?({:household_booking_limit, _}, reason)

  def error_text({:replacement_failed, :old_booking_cancelled, reason}),
    do:
      "⚠️ Your old booking was cancelled, but the replacement was not confirmed. Check /bookings before trying again.\n" <>
        error_text(reason)

  def error_text({:replacement_required, booking}),
    do:
      "You need to cancel your existing booking on this court before booking another slot:\n" <>
        summary(booking)

  def error_text({:already_booked, booking}),
    do: "You already hold this slot:\n" <> summary(booking)

  def error_text({:blocked, :multiple_existing_bookings}),
    do:
      "More than one booking exists on this court. Review /bookings; no booking will be cancelled automatically."

  def error_text({:household_booking_limit, _}),
    do:
      "The provider reports an active-booking limit for this court. It may belong to another household account and is not visible here. Cancel it in that account, then try again."

  def error_text({:cancellation_not_confirmed, _, _}),
    do:
      "Cancellation could not be confirmed. The replacement was not attempted; check /bookings before retrying."

  def error_text(:invalid_bookings),
    do: "Existing bookings could not be read safely. Nothing was changed."

  def error_text(:existing_booking_changed),
    do: "Your existing booking changed. Nothing was cancelled; reopen the slot to review it."

  def error_text(:slot_no_longer_open),
    do: "The target slot is no longer available. Your existing booking was kept."

  def error_text(:slot_in_past),
    do: "This slot has already started. Your existing booking was kept."

  def error_text({:booking_not_confirmed, _}),
    do:
      "The provider accepted the request, but a new booking could not be confirmed. Check /bookings before retrying."

  def error_text(reason) do
    if active_booking_limit?(reason),
      do: error_text({:household_booking_limit, reason}),
      else: "`#{inspect(reason) |> String.slice(0, 180)}`"
  end

  def summary(booking) do
    "#{booking["facility_name"]} · #{booking["start_date"] || booking["booking_date"] || booking["date"]} · #{booking["start_time"] || booking["booking_start_time"]}–#{booking["end_time"] || "?"}"
  end

  def active?(booking) do
    date = parse_date(booking["start_date"] || booking["booking_date"] || booking["date"])
    now = Clock.local_now()
    today = NaiveDateTime.to_date(now)

    end_time =
      parse_time(booking["end_time"] || booking["booking_end_time"] || booking["to_time"])

    expired =
      date != nil and
        (Date.compare(date, today) == :lt or
           (date == today and end_time != nil and
              Time.compare(end_time, NaiveDateTime.to_time(now)) != :gt))

    booking["type"] == "upcoming_bookings" and not expired and
      String.downcase(String.trim(to_string(booking["status"] || ""))) not in [
        "cancelled",
        "canceled",
        "rejected",
        "failed"
      ]
  end

  def same_court?(booking, slot) do
    case booking["facility_id"] do
      id when not is_nil(id) and id != "" -> to_string(id) == to_string(slot.facility_id)
      _ -> booking["facility_name"] == slot.facility_name
    end
  end

  def same_slot?(booking, slot) do
    same_court?(booking, slot) and
      parse_date(booking["start_date"] || booking["booking_date"] || booking["date"]) == slot.date and
      parse_time(booking["start_time"] || booking["booking_start_time"] || booking["from_time"]) ==
        slot.start_time and
      parse_time(booking["end_time"] || booking["booking_end_time"] || booking["to_time"]) ==
        slot.end_time
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        date

      _ ->
        case String.split(value, ~r/[\/-]/) do
          [day, month, year] ->
            months = ~w(jan feb mar apr may jun jul aug sep oct nov dec)

            m =
              case Integer.parse(month) do
                {m, ""} ->
                  m

                _ ->
                  Enum.find_index(months, &(&1 == String.downcase(month)))
                  |> case do
                    nil -> 0
                    i -> i + 1
                  end
              end

            case Date.new(String.to_integer(year), m, String.to_integer(day)) do
              {:ok, date} -> date
              _ -> nil
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp parse_date(_), do: nil

  defp parse_time(value) when is_binary(value) do
    value = String.trim(value)
    value = if byte_size(value) == 5, do: value <> ":00", else: value

    case Time.from_iso8601(value) do
      {:ok, time} -> Time.truncate(time, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp future_slot(slot) do
    now = Clock.local_now()

    if Date.compare(slot.date, NaiveDateTime.to_date(now)) == :lt or
         (slot.date == NaiveDateTime.to_date(now) and
            Time.compare(slot.start_time, NaiveDateTime.to_time(now)) != :gt),
       do: {:error, :slot_in_past},
       else: :ok
  end

  defp check_fee(slot) do
    max_fee = Config.load!().booking.max_fee_aed
    if slot.fee_aed > max_fee, do: {:error, {:fee_above_limit, slot.fee_aed, max_fee}}, else: :ok
  end

  defp serialized(fun) do
    case :global.trans({{__MODULE__, :mutations}, self()}, fun, [node()]) do
      :aborted -> {:error, :booking_busy}
      result -> result
    end
  end

  defp api(opts), do: Keyword.get(opts, :api, API)
  defp session(opts), do: Keyword.get_lazy(opts, :session, &Session.current!/0)

  defp invalidate do
    Cache.delete(:my_bookings)
    Cache.delete_prefix(:availability_day)
  end
end
