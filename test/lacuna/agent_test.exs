defmodule Lacuna.AgentTest do
  use ExUnit.Case, async: false

  alias Lacuna.Agent, as: Interface
  alias Lacuna.Backend.Cache

  defmodule Backend do
    def my_bookings(pid) do
      Agent.get_and_update(pid, fn s ->
        result = s.read_error || {:ok, %{"my_bookings" => %{"0" => s.bookings}}}
        {result, %{s | calls: s.calls ++ [:bookings]}}
      end)
    end

    def facility_availability(pid, court, date) do
      Agent.get_and_update(pid, fn s ->
        result = Map.get(s.availability, court, {:error, :unavailable})
        {result, %{s | calls: s.calls ++ [{:availability, court, date}]}}
      end)
    end

    def cancel_booking(pid, id) do
      Agent.get_and_update(pid, fn s ->
        result = s.cancel_error || {:ok, %{"private_response" => "must-not-leak"}}

        bookings =
          if match?({:ok, _}, result),
            do: Enum.reject(s.bookings, &(&1["booking_id"] == id)),
            else: s.bookings

        {result, %{s | calls: s.calls ++ [{:cancel, id}], bookings: bookings}}
      end)
    end
  end

  defmodule Booker do
    def book(slot, %{test_pid: pid}) do
      Agent.get_and_update(pid, fn s ->
        booking = Lacuna.AgentTest.booking("new", slot.facility_id, "18:00")

        result =
          s.book_error ||
            {:ok, %{booking: booking, slot: slot, response: %{"cookie" => "must-not-leak"}}}

        {result,
         %{
           s
           | calls: s.calls ++ [{:book, slot}],
             bookings: if(match?({:ok, _}, result), do: [booking | s.bookings], else: s.bookings)
         }}
      end)
    end
  end

  setup do
    start_supervised!(Cache)

    pid =
      start_supervised!(
        {Agent,
         fn ->
           %{
             bookings: [booking()],
             calls: [],
             read_error: nil,
             cancel_error: nil,
             book_error: nil,
             availability: %{"court-a" => {:ok, details()}, "court-b" => {:ok, details()}}
           }
         end}
      )

    opts = [
      api: Backend,
      session: pid,
      booker: Booker,
      context: %{test_pid: pid},
      courts: [
        %{id: "court-a", name: "Synthetic Court A"},
        %{id: "court-b", name: "Synthetic Court B"}
      ],
      now: ~U[2099-10-12 08:00:00Z]
    ]

    %{pid: pid, opts: opts}
  end

  for reason <- [:incomplete_bookings, :inconsistent_bookings] do
    test "inventory error #{reason} remains actionable and read only", %{pid: pid, opts: opts} do
      Agent.update(pid, &%{&1 | read_error: {:error, unquote(reason)}})
      assert %{"ok" => false, "error" => %{"code" => code}} = call("bookings", %{}, opts)
      assert code == unquote(Atom.to_string(reason))
      assert Agent.get(pid, & &1.calls) == [:bookings]
    end
  end

  test "fresh availability includes held slots, ownership, requested IDs and coverage", %{
    pid: pid,
    opts: opts
  } do
    {:ok, details} = Agent.get(pid, & &1.availability["court-a"])

    Agent.update(
      pid,
      &%{
        &1
        | availability:
            Map.put(
              &1.availability,
              "court-a",
              {:ok, Map.put(details, "slot_availability", %{"slot-19" => false})}
            )
      }
    )

    assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
    assert data["complete"]
    assert data["timezone"] == "Asia/Dubai"
    assert data["checked_at"] == "2099-10-12T08:00:00Z"
    assert data["policy"]["per_court_active_booking_limit"] == 1
    assert data["policy"]["source"] == "local_booking_guard"

    assert data["courts"] == [
             %{"court_id" => "court-a", "court_name" => "Synthetic Court A"},
             %{"court_id" => "court-b", "court_name" => "Synthetic Court B"}
           ]

    assert [
             %{"court_id" => "court-a", "date" => "2099-10-13", "error" => nil},
             %{"court_id" => "court-b", "date" => "2099-10-13", "error" => nil}
           ] = data["coverage"]

    assert Enum.map(data["slots"], & &1["eligibility"]["status"]) == [
             "replacement_required",
             "already_booked",
             "bookable",
             "bookable"
           ]

    assert Enum.at(data["slots"], 1)["eligibility"]["existing_booking"]["booking_id"] == "old"
    assert hd(data["slots"])["slot_id"] == "slot-18"
    assert hd(data["slots"])["fee_aed"] == 0
    assert hd(data["bookings"])["reference"] == "SYN-001"

    assert %{"ok" => true} =
             call("availability", Map.put(range(), "court_ids", ["court-b"]), opts)

    assert Agent.get(pid, & &1.calls) == [
             :bookings,
             {:availability, "court-a", ~D[2099-10-13]},
             {:availability, "court-b", ~D[2099-10-13]},
             :bookings,
             {:availability, "court-b", ~D[2099-10-13]}
           ]

    refute Jason.encode!(data) =~ "must-not-leak"
  end

  test "failed reads are partial coverage, never an empty successful calendar", %{
    pid: pid,
    opts: opts
  } do
    Agent.update(
      pid,
      &%{
        &1
        | availability:
            Map.put(&1.availability, "court-b", {:error, {:transport, "must-not-leak"}})
      }
    )

    assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
    refute data["complete"]
    assert length(data["slots"]) == 2
    assert Enum.at(data["coverage"], 1)["error"]["code"] == "transport"
    Agent.update(pid, &%{&1 | read_error: {:error, :invalid_bookings}})
    assert %{"ok" => true, "data" => unknown} = call("availability", range(), opts)
    refute unknown["complete"]
    assert unknown["bookings_error"]["code"] == "invalid_bookings"
    assert Enum.all?(unknown["slots"], &(&1["eligibility"]["status"] == "unknown"))

    assert %{"ok" => false, "error" => %{"code" => "invalid_bookings"}} =
             call("bookings", %{}, opts)

    refute Jason.encode!(data) =~ "must-not-leak"
  end

  for field <- ["booked_slots_on_date", "slot_availability"] do
    @malformed_field field
    test "malformed #{@malformed_field} produces incomplete coverage", %{pid: pid, opts: opts} do
      Agent.update(pid, fn state ->
        malformed = Map.put(details(), @malformed_field, "invalid")
        %{state | availability: Map.put(state.availability, "court-b", {:ok, malformed})}
      end)

      assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
      refute data["complete"]
      assert Enum.at(data["coverage"], 1)["error"]["code"] == "invalid_availability"
      refute Enum.any?(data["slots"], &(&1["court_id"] == "court-b"))
    end
  end

  test "absent optional occupancy fields preserve legacy availability", %{pid: pid, opts: opts} do
    Agent.update(pid, fn state ->
      legacy = Map.drop(details(), ["booked_slots_on_date", "slot_availability"])
      %{state | availability: Map.put(state.availability, "court-b", {:ok, legacy})}
    end)

    assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
    assert data["complete"]
    assert Enum.count(data["slots"], &(&1["court_id"] == "court-b")) == 2
  end

  test "list-shaped slot availability filters reads and stops replacement before cancellation", %{
    pid: pid,
    opts: opts
  } do
    Agent.update(pid, fn state ->
      vetoed =
        Map.put(details(), "slot_availability", [
          %{"facility_time_slot_id" => "slot-18", "is_available" => false}
        ])

      %{state | availability: Map.put(state.availability, "court-a", {:ok, vetoed})}
    end)

    assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
    assert data["complete"]
    refute Enum.any?(data["slots"], &(&1["court_id"] == "court-a" and &1["slot_id"] == "slot-18"))
    Agent.update(pid, &%{&1 | calls: []})

    assert %{"ok" => false, "error" => %{"code" => "slot_no_longer_open"}} =
             call("replace", mutation(), opts)

    refute Enum.any?(Agent.get(pid, & &1.calls), &match?({:cancel, _}, &1))
    refute Enum.any?(Agent.get(pid, & &1.calls), &match?({:book, _}, &1))
  end

  test "bookings normalize provider dates and aliases without private fields", %{
    pid: pid,
    opts: opts
  } do
    Agent.update(pid, &%{&1 | bookings: [booking() |> Map.delete("facility_id")]})

    assert %{"ok" => true, "data" => %{"bookings" => [b], "complete" => true}} =
             call("bookings", %{}, opts)

    assert b == %{
             "booking_id" => "old",
             "reference" => "SYN-001",
             "court_id" => "court-a",
             "court_name" => "Synthetic Court A",
             "date" => "2099-10-13",
             "start_time" => "19:00:00",
             "end_time" => "20:00:00",
             "status" => "Booked"
           }

    Agent.update(pid, &%{&1 | bookings: [Map.put(booking(), "start_date", "broken")]})

    assert %{"ok" => false, "error" => %{"code" => "invalid_bookings"}} =
             call("bookings", %{}, opts)
  end

  test "validation rejects invalid ranges and mutation inputs before any provider call", %{
    pid: pid,
    opts: opts
  } do
    for params <- [
          Map.put(range(), "date_from", "2099-02-30"),
          Map.put(range(), "date_to", "2099-10-12"),
          Map.put(range(), "date_from", "2099-10-11"),
          Map.put(range(), "date_to", "2099-10-26"),
          Map.put(range(), "court_ids", ["unknown"]),
          Map.put(range(), "court_ids", "court-a")
        ] do
      assert %{"ok" => false} = call("availability", params, opts)
    end

    for op <- ["book", "replace", "cancel"], confirmed <- [nil, false, "true"] do
      assert %{"ok" => false, "error" => %{"code" => "confirmation_required"}} =
               call(op, Map.put(mutation(), "confirmed", confirmed), opts)
    end

    for {key, value} <- [
          {"date", "2099-02-30"},
          {"court_id", "unknown"},
          {"court_id", 42},
          {"start_time", "24:00"},
          {"start_time", "19:00"},
          {"start_time", "18:00:00.5"},
          {"date", "2099-10-11"},
          {"date", "2099-10-26"}
        ] do
      assert %{"ok" => false} =
               call("book", %{"confirmed" => true, "slot" => Map.put(target(), key, value)}, opts)
    end

    for op <- ["replace", "cancel"] do
      assert %{"ok" => false} = call(op, Map.delete(mutation(), "expected_booking"), opts)
      assert %{"ok" => false} = call(op, Map.put(mutation(), "booking_id", ""), opts)

      assert %{"ok" => false, "error" => %{"code" => "slot_in_past"}} =
               call(op, put_in(mutation(), ["expected_booking", "date"], "2099-10-11"), opts)
    end

    assert Agent.get(pid, & &1.calls) == []
  end

  test "today's started slots are rejected and omitted; the Dubai browse window is inclusive", %{
    pid: pid,
    opts: opts
  } do
    today = opts |> Keyword.put(:now, ~U[2099-10-13 15:00:00Z])

    assert %{"ok" => false, "error" => %{"code" => "slot_in_past"}} =
             call("book", %{"confirmed" => true, "slot" => target()}, today)

    assert Agent.get(pid, & &1.calls) == []
    assert %{"ok" => true, "data" => %{"slots" => []}} = call("availability", range(), today)

    assert %{"ok" => true} =
             call(
               "availability",
               %{
                 "date_from" => "2099-10-25",
                 "date_to" => "2099-10-25",
                 "court_ids" => ["court-b"]
               },
               opts
             )
  end

  test "ordinary booking delegates fresh resolution and never silently cancels", %{
    pid: pid,
    opts: opts
  } do
    assert %{"ok" => false, "error" => %{"code" => "replacement_required"}} =
             call("book", mutation(), opts)

    assert Agent.get(pid, & &1.calls) == [:bookings]
    Agent.update(pid, &%{&1 | bookings: [], calls: []})

    forged =
      target()
      |> Map.put("fee_aed", -1000)
      |> Map.put("court_name", "forged")
      |> Map.put("slot_id", "forged")

    assert %{"ok" => true, "data" => %{"booking" => %{"booking_id" => "new"}, "verified" => true}} =
             result = call("book", %{"confirmed" => true, "slot" => forged}, opts)

    assert [:bookings, {:availability, "court-a", ~D[2099-10-13]}, {:book, slot}] =
             Agent.get(pid, & &1.calls)

    assert slot.slot_id == "slot-18"
    assert slot.fee_aed == 0
    refute Jason.encode!(result) =~ "must-not-leak"
  end

  test "replace retains snapshot consent, serialized ordering and explicit partial failure", %{
    pid: pid,
    opts: opts
  } do
    changed = put_in(mutation(), ["expected_booking", "start_time"], "18:00")

    assert %{"ok" => false, "error" => %{"code" => "existing_booking_changed"}} =
             call("replace", changed, opts)

    assert Agent.get(pid, & &1.calls) == [:bookings]
    Agent.update(pid, &%{&1 | calls: []})

    assert %{
             "ok" => true,
             "data" => %{
               "booking" => %{"booking_id" => "new"},
               "replaced_booking" => %{"booking_id" => "old"}
             }
           } = call("replace", mutation(), opts)

    assert [
             :bookings,
             :bookings,
             {:availability, "court-a", ~D[2099-10-13]},
             {:cancel, "old"},
             {:book, _}
           ] =
             Agent.get(pid, & &1.calls)

    Agent.update(
      pid,
      &%{
        &1
        | bookings: [booking()],
          calls: [],
          book_error: {:error, {:upstream, 500, "must-not-leak"}}
      }
    )

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "replacement_failed",
               "old_booking_cancelled" => true,
               "cause" => %{"code" => "upstream"}
             }
           } = failed = call("replace", mutation(), opts)

    assert Agent.get(pid, & &1.bookings) == []
    refute Jason.encode!(failed) =~ "must-not-leak"
  end

  test "replacement supports provider records identified by court name while retaining snapshot consent",
       %{pid: pid, opts: opts} do
    Agent.update(pid, &%{&1 | bookings: [Map.delete(booking(), "facility_id")]})

    assert %{
             "ok" => true,
             "data" => %{"replaced_booking" => %{"court_id" => "court-a", "booking_id" => "old"}}
           } = call("replace", mutation(), opts)
  end

  test "cancel re-reads ownership and exact snapshot before the verified existing path", %{
    pid: pid,
    opts: opts
  } do
    assert %{"ok" => false, "error" => %{"code" => "existing_booking_changed"}} =
             call("cancel", Map.put(mutation(), "booking_id", "other-account"), opts)

    assert %{"ok" => false, "error" => %{"code" => "existing_booking_changed"}} =
             call("cancel", put_in(mutation(), ["expected_booking", "date"], "2099-10-14"), opts)

    assert Agent.get(pid, & &1.calls) == [:bookings, :bookings]
    Agent.update(pid, &%{&1 | calls: []})

    assert %{
             "ok" => true,
             "data" => %{
               "booking" => %{"booking_id" => "old", "status" => "Cancelled"},
               "verified" => true
             }
           } = result = call("cancel", mutation(), opts)

    assert Agent.get(pid, & &1.calls) == [:bookings, {:cancel, "old"}]
    refute Jason.encode!(result) =~ "must-not-leak"
  end

  test "unverified cancellation, malformed availability and exceptions return safe errors", %{
    pid: pid,
    opts: opts
  } do
    Agent.update(
      pid,
      &%{&1 | cancel_error: {:error, {:cancellation_not_confirmed, "old", "must-not-leak"}}}
    )

    assert %{"ok" => false, "error" => %{"code" => "cancellation_not_confirmed"}} =
             call("cancel", mutation(), opts)

    Agent.update(pid, &%{&1 | availability: %{"court-a" => {:ok, %{}}}})

    assert %{
             "ok" => true,
             "data" => %{
               "complete" => false,
               "coverage" => [%{"error" => %{"code" => "invalid_availability"}}]
             }
           } = call("availability", Map.put(range(), "court_ids", ["court-a"]), opts)

    assert %{"ok" => false, "error" => %{"code" => "backend_unavailable"}} =
             call("bookings", %{}, Keyword.put(opts, :session, :not_a_pid))
  end

  test "mutation receipts reject mismatched bookings and retain cancellation after unsafe replacement output",
       %{pid: pid, opts: opts} do
    Agent.update(
      pid,
      &%{&1 | bookings: [], book_error: {:ok, %{booking: booking("wrong", "court-b", "18:00")}}}
    )

    assert %{"ok" => false, "error" => %{"code" => "booking_not_confirmed"}} =
             call("book", mutation(), opts)

    Agent.update(
      pid,
      &%{&1 | bookings: [booking()], calls: [], book_error: {:ok, %{booking: %{}}}}
    )

    assert %{
             "ok" => false,
             "error" => %{"code" => "replacement_failed", "old_booking_cancelled" => true}
           } = call("replace", mutation(), opts)

    assert Enum.any?(Agent.get(pid, & &1.calls), &(&1 == {:cancel, "old"}))
  end

  test "requested availability identity is validated before attaching the catalog identity", %{
    pid: pid,
    opts: opts
  } do
    for value <- ["court-other", nil, "", 42, %{}] do
      Agent.update(pid, fn state ->
        payload = Map.put(details(), "facility_id", value)
        %{state | availability: Map.put(state.availability, "court-b", {:ok, payload})}
      end)

      assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
      refute data["complete"]
      assert Enum.at(data["coverage"], 1)["error"]["code"] == "invalid_availability"
      refute Enum.any?(data["slots"], &(&1["court_id"] == "court-b"))
    end

    Agent.update(pid, fn state ->
      %{
        state
        | availability:
            Map.put(
              state.availability,
              "court-b",
              {:ok, Map.put(details(), "facility_id", "court-b")}
            )
      }
    end)

    assert %{"data" => %{"complete" => true}} = call("availability", range(), opts)
  end

  test "reads apply shared row, capacity and weekday validation to coverage", %{
    pid: pid,
    opts: opts
  } do
    for {field, value} <- [
          {"booked_slots_on_date", [%{"duration" => 60}]},
          {"slot_availability", %{"slot-18" => %{"is_available" => "maybe"}}},
          {"slots_capacity_details", %{"slot-18" => %{"capacity" => 2, "available" => nil}}},
          {"blocked_week_days", ["5"]},
          {"week_days", nil}
        ] do
      Agent.update(pid, fn state ->
        %{
          state
          | availability:
              Map.put(state.availability, "court-b", {:ok, Map.put(details(), field, value)})
        }
      end)

      assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
      refute data["complete"]
      assert Enum.at(data["coverage"], 1)["error"]["code"] == "invalid_availability"
      refute Enum.any?(data["slots"], &(&1["court_id"] == "court-b"))
    end
  end

  test "read eligibility does not advertise unsupported or unknown-price slots as bookable", %{
    pid: pid,
    opts: opts
  } do
    for {payload, reason} <- [
          {Map.put(details(), "is_chargeable", "1"), "paid_facility_unsupported"},
          {Map.delete(details(), "facility_rate"), "unknown_facility_price"},
          {Map.put(details(), "facility_rate", "0oops"), "unknown_facility_price"},
          {%{
             "is_facility_fixed_slot_based" => false,
             "facility_rate" => 0,
             "start_hour" => 18,
             "end_hour" => 20,
             "booking_hrs" => 1
           }, "unsupported_booking_mode"}
        ] do
      Agent.update(pid, fn state ->
        %{state | availability: Map.put(state.availability, "court-b", {:ok, payload})}
      end)

      assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
      assert data["complete"]
      slots = Enum.filter(data["slots"], &(&1["court_id"] == "court-b"))
      assert slots != []

      assert Enum.all?(
               slots,
               &(&1["eligibility"] == %{"status" => "blocked", "reason" => reason})
             )

      assert Enum.all?(slots, &is_nil(&1["fee_aed"]))
    end
  end

  test "current free fixed metadata without rate and empty list capacity stays supported", %{
    pid: pid,
    opts: opts
  } do
    payload =
      details()
      |> Map.delete("facility_rate")
      |> Map.put("is_chargeable", "0")
      |> Map.put("slots_capacity_details", [])

    Agent.update(pid, fn state ->
      %{state | availability: Map.put(state.availability, "court-b", {:ok, payload})}
    end)

    assert %{"ok" => true, "data" => data} = call("availability", range(), opts)
    assert data["complete"]
    slots = Enum.filter(data["slots"], &(&1["court_id"] == "court-b"))
    assert Enum.all?(slots, &(&1["eligibility"]["status"] == "bookable" and &1["fee_aed"] == 0))
  end

  def booking(id \\ "old", court \\ "court-a", time \\ "19:00") do
    %{
      "booking_id" => id,
      "booking_no" => "SYN-001",
      "facility_id" => court,
      "facility_name" =>
        if(court == "court-a", do: "Synthetic Court A", else: "Synthetic Court B"),
      "type" => "upcoming_bookings",
      "status" => "Booked",
      "start_date" => "13-Oct-2099",
      "start_time" => time,
      "end_time" => if(time == "19:00", do: "20:00", else: "19:00"),
      "cookie" => "must-not-leak"
    }
  end

  defp details,
    do: %{
      "is_facility_fixed_slot_based" => "1",
      "fixed_time_slots" => %{"slot-18" => "18:00 - 19:00", "slot-19" => "19:00 - 20:00"},
      "facility_rate" => "0",
      "booked_slots_on_date" => []
    }

  defp range, do: %{"date_from" => "2099-10-13", "date_to" => "2099-10-13"}

  defp target,
    do: %{
      "court_id" => "court-a",
      "date" => "2099-10-13",
      "start_time" => "18:00",
      "end_time" => "19:00"
    }

  defp mutation,
    do: %{
      "slot" => target(),
      "confirmed" => true,
      "booking_id" => "old",
      "expected_booking" => %{target() | "start_time" => "19:00", "end_time" => "20:00"}
    }

  defp call(operation, params, opts),
    do: Interface.dispatch(%{"operation" => operation, "params" => params}, opts)

  test "the JSON entrypoint rejects malformed input and unknown operations safely" do
    for {input, expected_code} <- [
          {"not json", "invalid_input"},
          {"[]", "invalid_input"},
          {"null", "invalid_input"},
          {~s({"operation":"bookings","params":null}), "invalid_input"},
          {~s({"operation":"eval","params":{"code":"must-not-run"}}), "unknown_operation"},
          {~s({"operation":"book","params":{"confirmed":false,"api":"must-not-run"}}),
           "confirmation_required"}
        ] do
      assert %{"ok" => false, "error" => %{"code" => code, "message" => message}} =
               input |> Lacuna.Agent.dispatch_json() |> Jason.decode!()

      assert code == expected_code
      assert is_binary(message)
    end
  end
end
