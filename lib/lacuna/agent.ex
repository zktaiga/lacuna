defmodule Lacuna.Agent do
  @moduledoc """
  Allowlisted JSON primitives using the current operator's authenticated session.

  `dispatch_json/1` accepts only an operation and JSON params, never executable
  code or dependency options. `dispatch/2` exposes trusted dependency injection
  for isolated tests. Reads are fresh, do not tick the poller, and do not discover
  or change courts. Mutations require exact targets and explicit confirmation.
  """

  alias Lacuna.{Bookings, Slot}
  alias Lacuna.Backend.{API, Availability, Courts, Session}

  @operations ~w(availability bookings book replace cancel)
  @window_days 14

  def dispatch_json(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, request} -> dispatch(request)
      {:error, _} -> failure(:invalid_input)
    end
    |> Jason.encode!()
  end

  def dispatch_json(_), do: Jason.encode!(failure(:invalid_input))

  def dispatch(request, opts \\ [])

  def dispatch(%{"operation" => operation, "params" => params}, opts)
      when is_binary(operation) and is_map(params) do
    if operation in @operations do
      case execute(operation, params, opts) do
        {:ok, data} -> %{"ok" => true, "data" => data}
        {:error, reason} -> failure(reason)
      end
    else
      failure(:unknown_operation)
    end
  rescue
    _ -> failure(:backend_unavailable)
  catch
    _, _ -> failure(:backend_unavailable)
  end

  def dispatch(_, _), do: failure(:invalid_input)

  defp execute("bookings", _params, opts) do
    with {:ok, courts} <- catalog(opts),
         {:ok, _raw, normalized} <- read_bookings(courts, opts) do
      {:ok, Map.merge(metadata(opts), %{"bookings" => normalized, "complete" => true})}
    end
  end

  defp execute("availability", params, opts) do
    with {:ok, from} <- date(params["date_from"]),
         {:ok, to} <- date(params["date_to"]),
         :ok <- browse_range(from, to, opts),
         {:ok, all_courts} <- catalog(opts),
         {:ok, courts} <- selected_courts(params, all_courts) do
      bookings = read_bookings(all_courts, opts)

      {raw, normalized, bookings_error} =
        case bookings do
          {:ok, raw, normalized} -> {raw, normalized, nil}
          {:error, reason} -> {[], [], public_error(reason)}
        end

      cells =
        for court <- courts,
            day <- Date.range(from, to),
            do: availability_cell(court, day, raw, bookings_error, all_courts, opts)

      coverage = Enum.map(cells, &elem(&1, 0))
      slots = Enum.flat_map(cells, &elem(&1, 1))

      data =
        Map.merge(metadata(opts), %{
          "courts" => Enum.map(courts, &public_court/1),
          "slots" => slots,
          "bookings" => normalized,
          "bookings_error" => bookings_error,
          "coverage" => coverage,
          "complete" => bookings_error == nil and Enum.all?(coverage, &is_nil(&1["error"]))
        })

      {:ok, data}
    end
  end

  defp execute(operation, params, opts) when operation in ~w(book replace cancel) do
    with :ok <- confirmed(params),
         {:ok, courts} <- catalog(opts),
         {:ok, consent} <- consent(operation, params, courts, opts),
         {:ok, slot} <- mutation_slot(operation, params, courts, opts) do
      mutate(operation, slot, consent, courts, opts)
    end
  end

  defp mutate("book", slot, _consent, courts, opts) do
    with {:ok, result} <- Bookings.book(slot, context(opts), booking_opts(opts)),
         {:ok, booking} <- creation_receipt(result, slot, courts) do
      {:ok, Map.merge(metadata(opts), %{"booking" => booking, "verified" => true})}
    end
  end

  defp mutate("replace", slot, {id, expected}, courts, opts) do
    # Consent uses catalog IDs; snapshot/1 intentionally retains the provider's
    # name fallback when facility_id is absent. Validate the caller's tuple,
    # then pass the exact observed tuple for Bookings' serialized recheck.
    with {:ok, raw, _} <- read_bookings(courts, opts),
         {:ok, old, _} <- owned_booking(raw, id, expected, courts),
         mutation_opts =
           Keyword.put(booking_opts(opts), :expected_booking, Bookings.snapshot(old)),
         {:ok, result} <- Bookings.replace(slot, id, context(opts), mutation_opts) do
      receipt =
        safely(fn ->
          with {:ok, booking} <- creation_receipt(result, slot, courts),
               {:ok, old} <- normalize_booking(result[:replaced_booking], courts) do
            {:ok,
             Map.merge(metadata(opts), %{
               "booking" => booking,
               "replaced_booking" => old,
               "verified" => true
             })}
          end
        end)

      case receipt do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, {:replacement_failed, :old_booking_cancelled, reason}}
      end
    end
  end

  defp mutate("cancel", _slot, {id, expected}, courts, opts) do
    # Use the same lock as Bookings so ownership/snapshot checks cannot race
    # another local mutation. Bookings.cancel retains provider verification.
    case :global.trans(
           {{Bookings, :mutations}, self()},
           fn ->
             with {:ok, raw, _} <- read_bookings(courts, opts),
                  {:ok, _raw_old, old} <- owned_booking(raw, id, expected, courts),
                  {:ok, _} <- Bookings.cancel(id, booking_opts(opts)) do
               {:ok,
                Map.merge(metadata(opts), %{
                  "booking" => Map.put(old, "status", "Cancelled"),
                  "verified" => true
                })}
             end
           end,
           [node()]
         ) do
      :aborted -> {:error, :booking_busy}
      result -> result
    end
  end

  defp creation_receipt(%{booking: raw}, slot, courts) when is_map(raw) do
    with {:ok, booking} <- normalize_booking(raw, courts),
         true <- Bookings.same_slot?(raw, slot) do
      {:ok, booking}
    else
      _ -> {:error, :booking_not_confirmed}
    end
  end

  defp creation_receipt(_, _, _), do: {:error, :booking_not_confirmed}

  defp availability_cell(court, day, raw, bookings_error, courts, opts) do
    result =
      safely(fn ->
        with {:ok, details} <- api(opts).facility_availability(session(opts), court.id, day),
             {:ok, slots} <- browsing_slots(details, court, day, raw) do
          support = Availability.validate_bookable(details)

          slots =
            slots
            |> Enum.filter(&future?(&1, opts))
            |> Enum.map(&public_slot(&1, raw, bookings_error, courts, support))

          {:ok, slots}
        end
      end)

    {slots, error} =
      case result do
        {:ok, slots} -> {slots, nil}
        {:error, reason} -> {[], public_error(reason)}
      end

    coverage =
      Map.merge(public_court(court), %{
        "date" => Date.to_iso8601(day),
        "checked_at" => timestamp(opts),
        "error" => error
      })

    {coverage, slots}
  end

  defp browsing_slots(details, court, day, raw) when is_map(details) do
    # Provider responses can omit the ID; attach the requested identity before
    # parsing so held-slot matching works. Catalog names are authoritative here.
    with :ok <- Availability.validate(details),
         :ok <- requested_identity(details, court.id) do
      details =
        details |> Map.put("facility_id", court.id) |> Map.put("facility_name", court.name)

      {:ok, Bookings.browsing_slots(details, day, raw)}
    end
  rescue
    _ -> {:error, :invalid_availability}
  end

  defp browsing_slots(_, _, _, _), do: {:error, :invalid_availability}

  defp requested_identity(details, requested) do
    case Map.fetch(details, "facility_id") do
      :error -> :ok
      {:ok, ^requested} -> :ok
      _ -> {:error, :invalid_availability}
    end
  end

  defp public_slot(slot, raw, bookings_error, courts, support) do
    eligibility =
      case support do
        {:error, reason} ->
          %{"status" => "blocked", "reason" => public_error(reason)["code"]}

        :ok ->
          if bookings_error,
            do: %{"status" => "unknown"},
            else: public_eligibility(Bookings.eligibility(slot, raw), courts)
      end

    %{
      "court_id" => slot.facility_id,
      "court_name" => slot.facility_name,
      "date" => Date.to_iso8601(slot.date),
      "start_time" => Time.to_iso8601(slot.start_time),
      "end_time" => Time.to_iso8601(slot.end_time),
      "slot_id" => scalar(slot.slot_id),
      "fee_aed" => if(support == :ok, do: slot.fee_aed),
      "eligibility" => eligibility
    }
  end

  defp public_eligibility(:bookable, _), do: %{"status" => "bookable"}
  defp public_eligibility({:blocked, _}, _), do: %{"status" => "blocked"}

  defp public_eligibility({status, booking}, courts)
       when status in [:already_booked, :replacement_required] do
    {:ok, normalized} = normalize_booking(booking, courts)
    %{"status" => Atom.to_string(status), "existing_booking" => normalized}
  end

  defp read_bookings(courts, opts) do
    safely(fn ->
      with {:ok, raw} <- Bookings.upcoming(booking_opts(opts)),
           {:ok, normalized} <- normalize_bookings(raw, courts) do
        {:ok, raw, normalized}
      end
    end)
  end

  defp normalize_bookings(raw, courts) do
    Enum.reduce_while(raw, {:ok, []}, fn booking, {:ok, acc} ->
      case normalize_booking(booking, courts) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_booking(booking, courts) when is_map(booking) do
    {raw_court, day, start_time, end_time} = Bookings.snapshot(booking)

    court =
      Enum.find(courts, &(&1.id == raw_court)) ||
        if(is_nil(booking["facility_id"]) or booking["facility_id"] == "",
          do: Enum.find(courts, &(&1.name == booking["facility_name"]))
        )

    id = scalar(booking["booking_id"])
    court_id = if court, do: court.id, else: scalar(booking["facility_id"])

    if id not in [nil, ""] and court_id not in [nil, ""] and match?(%Date{}, day) and
         match?(%Time{}, start_time) and match?(%Time{}, end_time) and
         Time.compare(start_time, end_time) == :lt do
      {:ok,
       %{
         "booking_id" => id,
         "reference" => scalar(booking["booking_no"]),
         "court_id" => court_id,
         "court_name" => if(court, do: court.name, else: scalar(booking["facility_name"])),
         "date" => Date.to_iso8601(day),
         "start_time" => Time.to_iso8601(start_time),
         "end_time" => Time.to_iso8601(end_time),
         "status" => scalar(booking["status"])
       }}
    else
      {:error, :invalid_bookings}
    end
  rescue
    _ -> {:error, :invalid_bookings}
  end

  defp normalize_booking(_, _), do: {:error, :invalid_bookings}

  defp owned_booking(raw, id, {court, day, start_time, end_time}, courts) do
    case Enum.filter(raw, &(scalar(&1["booking_id"]) == id)) do
      [booking] ->
        with {:ok, normalized} <- normalize_booking(booking, courts) do
          expected =
            {court, Date.to_iso8601(day), Time.to_iso8601(start_time), Time.to_iso8601(end_time)}

          observed =
            {normalized["court_id"], normalized["date"], normalized["start_time"],
             normalized["end_time"]}

          if observed == expected,
            do: {:ok, booking, normalized},
            else: {:error, :existing_booking_changed}
        end

      _ ->
        {:error, :existing_booking_changed}
    end
  end

  defp catalog(opts) do
    result =
      case Keyword.fetch(opts, :courts) do
        {:ok, courts} -> {:ok, courts}
        :error -> Courts.load()
      end

    with {:ok, courts} when is_list(courts) <- result do
      valid =
        Enum.all?(courts, fn
          %{id: id, name: name} -> is_binary(id) and id != "" and is_binary(name) and name != ""
          _ -> false
        end)

      if valid and Enum.uniq_by(courts, & &1.id) == courts,
        do: {:ok, courts},
        else: {:error, :courts_unavailable}
    end
  end

  defp selected_courts(params, courts) do
    case Map.fetch(params, "court_ids") do
      :error ->
        {:ok, courts}

      {:ok, ids} when is_list(ids) and ids != [] ->
        if Enum.all?(ids, fn id -> is_binary(id) and Enum.any?(courts, &(&1.id == id)) end),
          do: {:ok, Enum.filter(courts, &(&1.id in ids))},
          else: {:error, :invalid_court}

      _ ->
        {:error, :invalid_court}
    end
  end

  defp confirmed(%{"confirmed" => true}), do: :ok
  defp confirmed(_), do: {:error, :confirmation_required}

  defp consent("book", _params, _courts, _opts), do: {:ok, nil}

  defp consent(_, params, courts, opts) do
    with id when is_binary(id) and byte_size(id) > 0 <- params["booking_id"],
         {:ok, expected} <- exact_slot(params["expected_booking"], courts),
         :ok <- future_target(expected, opts) do
      {:ok, {id, {expected.facility_id, expected.date, expected.start_time, expected.end_time}}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_input}
    end
  end

  defp mutation_slot("cancel", _params, _courts, _opts), do: {:ok, nil}

  defp mutation_slot(_, params, courts, opts) do
    with {:ok, slot} <- exact_slot(params["slot"], courts),
         :ok <- future_target(slot, opts),
         :ok <- browse_range(slot.date, slot.date, opts),
         do: {:ok, slot}
  end

  defp exact_slot(%{"court_id" => id} = params, courts) when is_binary(id) do
    with %{name: name} <- Enum.find(courts, &(&1.id == id)),
         {:ok, day} <- date(params["date"]),
         {:ok, start_time} <- time(params["start_time"]),
         {:ok, end_time} <- time(params["end_time"]),
         :lt <- Time.compare(start_time, end_time) do
      {:ok,
       %Slot{
         facility_id: id,
         facility_name: name,
         date: day,
         start_time: start_time,
         end_time: end_time
       }}
    else
      nil -> {:error, :invalid_court}
      _ -> {:error, :invalid_input}
    end
  end

  defp exact_slot(_, _), do: {:error, :invalid_input}

  defp date(value) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      case Date.from_iso8601(value) do
        {:ok, date} -> {:ok, date}
        _ -> {:error, :invalid_input}
      end
    else
      {:error, :invalid_input}
    end
  end

  defp date(_), do: {:error, :invalid_input}

  defp time(value) when is_binary(value) do
    if Regex.match?(~r/^\d{2}:\d{2}(:\d{2})?$/, value) do
      case Time.from_iso8601(if(byte_size(value) == 5, do: value <> ":00", else: value)) do
        {:ok, time} -> {:ok, time}
        _ -> {:error, :invalid_input}
      end
    else
      {:error, :invalid_input}
    end
  end

  defp time(_), do: {:error, :invalid_input}

  defp browse_range(from, to, opts) do
    today = NaiveDateTime.to_date(local_now(opts))
    last = Date.add(today, @window_days - 1)

    if Date.compare(from, today) != :lt and Date.compare(to, last) != :gt and
         Date.compare(from, to) != :gt, do: :ok, else: {:error, :invalid_date_range}
  end

  defp future_target(slot, opts),
    do: if(future?(slot, opts), do: :ok, else: {:error, :slot_in_past})

  defp future?(slot, opts),
    do:
      NaiveDateTime.compare(NaiveDateTime.new!(slot.date, slot.start_time), local_now(opts)) ==
        :gt

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp local_now(opts),
    do: opts |> now() |> DateTime.add(4 * 3600, :second) |> DateTime.to_naive()

  defp timestamp(opts), do: opts |> now() |> DateTime.to_iso8601()
  defp api(opts), do: Keyword.get(opts, :api, API)
  defp session(opts), do: Keyword.get_lazy(opts, :session, &Session.current!/0)
  defp context(opts), do: Map.put(Keyword.get(opts, :context, %{}), :actor, :agent)

  defp booking_opts(opts),
    do: opts |> Keyword.take([:api, :session, :booker]) |> Keyword.put(:cached, false)

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(_), do: nil
  defp public_court(court), do: %{"court_id" => court.id, "court_name" => court.name}

  defp metadata(opts),
    do: %{
      "timezone" => "Asia/Dubai",
      "checked_at" => timestamp(opts),
      "policy" => %{
        "per_court_active_booking_limit" => 1,
        "source" => "local_booking_guard",
        "browse_window_days" => @window_days
      }
    }

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    _, _ -> {:error, :backend_unavailable}
  end

  defp failure(reason), do: %{"ok" => false, "error" => public_error(reason)}

  defp public_error({:replacement_failed, :old_booking_cancelled, reason}) do
    %{
      "code" => "replacement_failed",
      "message" =>
        "The old booking was cancelled, but the replacement was not confirmed. Re-read bookings before retrying.",
      "old_booking_cancelled" => true,
      "cause" => public_error(reason)
    }
  end

  defp public_error({:already_booked, _}), do: public_error(:already_booked)
  defp public_error({:replacement_required, _}), do: public_error(:replacement_required)
  defp public_error({:blocked, _}), do: public_error(:blocked)
  defp public_error({:household_booking_limit, _}), do: public_error(:household_booking_limit)
  defp public_error({:booking_not_confirmed, _}), do: public_error(:booking_not_confirmed)

  defp public_error({:cancellation_not_confirmed, _, _}),
    do: public_error(:cancellation_not_confirmed)

  defp public_error({:fee_above_limit, _, _}), do: public_error(:fee_above_limit)
  defp public_error({:transport, _}), do: public_error(:transport)
  defp public_error({:http_status, _, _}), do: public_error(:http_status)
  defp public_error({:upstream, _, _}), do: public_error(:upstream)
  defp public_error(:not_yet_discovered), do: public_error(:courts_unavailable)

  defp public_error(reason) do
    {code, message} =
      case reason do
        :invalid_input ->
          {"invalid_input",
           "Expected valid operation params, ISO dates and exact local slot times."}

        :unknown_operation ->
          {"unknown_operation",
           "Unknown operation. Use availability, bookings, book, replace or cancel."}

        :confirmation_required ->
          {"confirmation_required", "Explicit confirmation of this exact mutation is required."}

        :invalid_court ->
          {"invalid_court", "Choose a known configured court ID."}

        :invalid_date_range ->
          {"invalid_date_range",
           "Dates must be ordered and inside the local 14-day browse window, including today."}

        :courts_unavailable ->
          {"courts_unavailable", "The configured court catalog is unavailable."}

        :invalid_bookings ->
          {"invalid_bookings", "Current bookings could not be read safely."}

        :invalid_availability ->
          {"invalid_availability",
           "Availability could not be read safely for this court and date."}

        :unsupported_booking_mode ->
          {"unsupported_booking_mode",
           "Only free fixed-slot facilities are supported for booking changes."}

        :paid_facility_unsupported ->
          {"paid_facility_unsupported",
           "Chargeable facilities are not supported. Nothing was cancelled."}

        :unknown_facility_price ->
          {"unknown_facility_price",
           "The facility could not be verified as free. Nothing was cancelled."}

        :existing_booking_changed ->
          {"existing_booking_changed",
           "The owned booking no longer matches the approved snapshot. Nothing was cancelled."}

        :slot_no_longer_open ->
          {"slot_no_longer_open", "The target slot is no longer open."}

        :slot_in_past ->
          {"slot_in_past", "The target slot has already started."}

        :already_booked ->
          {"already_booked", "This account already holds the target slot."}

        :replacement_required ->
          {"replacement_required",
           "An existing booking on this court requires an explicitly approved replacement."}

        :blocked ->
          {"blocked",
           "Multiple bookings exist on this court. Review bookings before changing anything."}

        :household_booking_limit ->
          {"household_booking_limit",
           "The provider reports an active booking limit; another household account may hold the booking."}

        :booking_not_confirmed ->
          {"booking_not_confirmed",
           "Creation could not be verified. Re-read bookings before retrying."}

        :cancellation_not_confirmed ->
          {"cancellation_not_confirmed",
           "Cancellation could not be verified. Re-read bookings before retrying."}

        :fee_above_limit ->
          {"fee_above_limit",
           "The freshly observed slot fee exceeds the configured booking limit."}

        :booking_busy ->
          {"booking_busy", "Another booking mutation is in progress."}

        :transport ->
          {"transport", "The provider request failed in transport."}

        :http_status ->
          {"http_status", "The provider returned an unsuccessful HTTP status."}

        :upstream ->
          {"upstream", "The provider rejected the request."}

        _ ->
          {"backend_unavailable",
           "The backend operation failed. Re-read bookings before retrying a mutation."}
      end

    %{"code" => code, "message" => message}
  end
end
