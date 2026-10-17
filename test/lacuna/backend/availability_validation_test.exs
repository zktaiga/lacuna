defmodule Lacuna.Backend.AvailabilityValidationTest do
  use ExUnit.Case, async: true

  alias Lacuna.Backend.Availability

  defp fixed do
    %{
      "is_facility_fixed_slot_based" => "1",
      "fixed_time_slots" => %{"a" => "18:00 - 19:00", "b" => "19:00 - 20:00"},
      "facility_rate" => "0"
    }
  end

  defp window do
    %{
      "is_facility_fixed_slot_based" => false,
      "start_hour" => 18,
      "start_min" => 0,
      "end_hour" => 21,
      "end_min" => 0,
      "booking_hrs" => 1,
      "facility_rate" => 0
    }
  end

  test "shared validation accepts absent optional legacy occupancy and both fixed shapes" do
    assert :ok == Availability.validate(fixed())
    assert :ok == Availability.validate(window())
    list = [%{"id" => 1, "start_time" => "18:00", "duration" => "60"}]
    details = Map.put(fixed(), "fixed_time_slots", list)
    assert :ok == Availability.validate(details)

    assert [%{slot_id: "1", duration_minutes: 60}] =
             Availability.open_slots(details, ~D[2099-05-08])
  end

  test "present malformed occupancy and grids fail closed, not just top-level containers" do
    for {key, value} <- [
          {"booked_slots_on_date", nil},
          {"booked_slots_on_date", "bad"},
          {"booked_slots_on_date", [nil]},
          {"booked_slots_on_date", [%{"duration" => 60}]},
          {"booked_slots_on_date", [%{"start_time" => "18:00"}]},
          {"booked_slots_on_date", [%{"start_time" => "18:00", "duration" => 0}]},
          {"booked_slots_on_date", [%{"start_time" => "18:00", "duration" => "60oops"}]},
          {"booked_slots_on_date", [%{"start_time" => "25:00", "duration" => 60}]},
          {"slot_availability", nil},
          {"slot_availability", 0},
          {"slot_availability", [nil]},
          {"slot_availability", [%{"is_available" => false}]},
          {"slot_availability", %{"a" => nil}},
          {"slot_availability", %{"a" => %{"is_available" => "maybe"}}},
          {"slot_availability", %{"a" => %{"slots" => "1oops"}}},
          {"slot_availability", [%{"facility_time_slot_id" => ""}]},
          {"slot_availability", [%{"facility_time_slot_id" => %{}}]},
          {"fixed_time_slots", nil},
          {"fixed_time_slots", "bad"},
          {"fixed_time_slots", %{"" => "18:00 - 19:00"}},
          {"fixed_time_slots", %{"a" => "18:00"}},
          {"fixed_time_slots", %{"a" => "19:00 - 18:00"}},
          {"fixed_time_slots", [%{"id" => "a", "start_time" => "18:00", "duration" => -60}]},
          {"is_facility_fixed_slot_based", nil}
        ] do
      details = Map.put(fixed(), key, value)

      assert {:error, :invalid_availability} == Availability.validate(details),
             inspect({key, value})

      assert [] == Availability.open_slots(details, ~D[2099-05-08])
    end

    assert {:error, :invalid_availability} == Availability.validate(nil)
    assert {:error, :invalid_availability} == Availability.validate(%{})
  end

  test "conflicting duplicate IDs are rejected before list-to-map normalization" do
    for {key, rows} <- [
          {"slot_availability",
           [
             %{"facility_time_slot_id" => 1, "is_available" => false},
             %{"facility_time_slot_id" => "1", "is_available" => true}
           ]},
          {"fixed_time_slots",
           [
             %{"id" => 1, "start_time" => "18:00", "duration" => 60},
             %{"id" => "1", "start_time" => "19:00", "duration" => 60}
           ]},
          {"fixed_time_slots",
           %{"a" => "18:00 - 19:00", 1 => "18:00 - 19:00", "1" => "19:00 - 20:00"}}
        ] do
      assert {:error, :invalid_availability} == Availability.validate(Map.put(fixed(), key, rows))
    end
  end

  test "same-start fixed entries cannot collapse through stable slot or callback keys" do
    for slots <- [
          %{"a" => "18:00 - 19:00", "b" => "18:00 - 20:00"},
          %{"a" => "18:00 - 19:00", "b" => "18:00 - 19:00"},
          [
            %{"id" => "a", "start_time" => "18:00", "duration" => 60},
            %{"id" => "b", "start_time" => "18:00", "duration" => 120}
          ]
        ] do
      details = Map.put(fixed(), "fixed_time_slots", slots)
      assert {:error, :invalid_availability} == Availability.validate(details)
      assert {:error, :invalid_availability} == Availability.validate_bookable(details)
      assert [] == Availability.open_slots(details, ~D[2099-05-08])
    end
  end

  test "current Android capacity veto uses available, never the opaque slots string" do
    details =
      Map.put(fixed(), "slots_capacity_details", %{
        "a" => %{"capacity" => 3, "available" => 0, "booked" => 0, "slots" => "opaque"},
        "b" => %{"capacity" => 3, "available" => 2, "booked" => 0, "slots" => "0"}
      })

    assert Enum.map(Availability.open_slots(details, ~D[2099-05-08]), & &1.slot_id) == ["b"]
    assert :ok == Availability.validate(details)
    # Neither positive capacity nor a permissive availability flag can override ANY overlap.
    details =
      details
      |> Map.put("slot_availability", %{"b" => %{"is_available" => true, "slots" => 2}})
      |> Map.put("booked_slots_on_date", [%{"start_time" => "19:30", "duration" => 15}])

    assert [] == Availability.open_slots(details, ~D[2099-05-08])
  end

  test "malformed capacity metadata fails safe even for unrelated IDs" do
    for value <- [
          nil,
          [nil],
          "bad",
          %{"a" => nil},
          %{"a" => %{}},
          %{"a" => %{"capacity" => "3", "available" => 1}},
          %{"a" => %{"capacity" => 3, "available" => nil}},
          %{"a" => %{"capacity" => 3, "available" => 1, "slots" => 1}},
          %{"unknown" => %{"capacity" => 3, "available" => "1"}}
        ] do
      details = Map.put(fixed(), "slots_capacity_details", value)
      assert {:error, :invalid_availability} == Availability.validate(details)
      assert [] == Availability.open_slots(details, ~D[2099-05-08])
    end

    assert :ok == Availability.validate(Map.put(fixed(), "slots_capacity_details", %{}))

    details =
      Map.put(fixed(), "slots_capacity_details", %{"a" => %{"capacity" => 0, "available" => 0}})

    assert length(Availability.open_slots(details, ~D[2099-05-08])) == 2
  end

  test "indexed blocked weekdays resolve through metadata, never guessed index conventions" do
    details =
      fixed()
      |> Map.put("blocked_week_days", ["42"])
      |> Map.put("week_days", [
        %{"week_day_index" => 42, "week_day_key" => "FRIDAY", "week_day_title" => "Friday"}
      ])

    assert [] == Availability.open_slots(details, ~D[2026-05-08])
    assert length(Availability.open_slots(details, ~D[2026-05-09])) == 2
    assert :ok == Availability.validate(details)
    # Index 5 cannot be assumed to mean Friday without a matching metadata row.
    assert {:error, :invalid_availability} ==
             Availability.validate(Map.put(details, "blocked_week_days", ["5"]))
  end

  test "malformed weekday metadata fails validation instead of silently permitting a date" do
    for {key, value} <- [
          {"blocked_week_days", nil},
          {"blocked_week_days", "Fri"},
          {"blocked_week_days", [nil]},
          {"blocked_week_days", ["5"]},
          {"blocked_week_days", ["Frieday"]},
          {"week_days", nil},
          {"week_days", %{}},
          {"week_days", [nil]},
          {"week_days",
           [%{"week_day_index" => 5, "week_day_key" => "nonsense", "week_day_title" => "Friday"}]},
          {"week_days",
           [%{"week_day_index" => 5, "week_day_key" => "Fri", "week_day_title" => "Monday"}]},
          {"week_days",
           [
             %{"week_day_index" => 5, "week_day_key" => "Fri", "week_day_title" => "Friday"},
             %{"week_day_index" => 5, "week_day_key" => "Sat", "week_day_title" => "Saturday"}
           ]}
        ] do
      assert {:error, :invalid_availability} ==
               Availability.validate(Map.put(fixed(), key, value))
    end
  end

  test "clock enumeration is bounded when the next step crosses midnight" do
    details =
      window() |> Map.put("start_hour", 23) |> Map.put("end_hour", 23) |> Map.put("end_min", 59)

    task = Task.async(fn -> Availability.open_slots(details, ~D[2099-05-08]) end)
    result = Task.yield(task, 100) || Task.shutdown(task, :brutal_kill)
    assert result == {:ok, []}
    assert [] == Availability.open_slots(window(), ~D[2099-05-08], granularity_minutes: 0)
    assert [] == Availability.open_slots(window(), ~D[2099-05-08], granularity_minutes: -1)
  end

  test "overnight and invalid duration windows are explicitly rejected" do
    for details <- [
          Map.put(fixed(), "fixed_time_slots", %{"a" => "23:00 - 01:00"}),
          Map.put(fixed(), "booked_slots_on_date", [%{"start_time" => "23:30", "duration" => 60}]),
          window() |> Map.put("start_hour", 23) |> Map.put("end_hour", 1),
          Map.put(window(), "booking_hrs", 0),
          Map.put(window(), "booking_hrs", "oops")
        ] do
      assert {:error, :invalid_availability} == Availability.validate(details)
      assert [] == Availability.open_slots(details, ~D[2099-05-08])
    end
  end

  test "mutation support is strictly free fixed only with trustworthy zero pricing" do
    assert :ok == Availability.validate_bookable(fixed())

    assert :ok ==
             Availability.validate_bookable(
               fixed()
               |> Map.delete("facility_rate")
               |> Map.put("is_chargeable", "0")
             )

    assert [%{fee_aed: 0} | _] =
             Availability.open_slots(
               fixed() |> Map.delete("facility_rate") |> Map.put("is_chargeable", 0),
               ~D[2099-05-08]
             )

    assert {:error, :unsupported_booking_mode} == Availability.validate_bookable(window())

    for value <- [true, 1, "1"] do
      assert {:error, :paid_facility_unsupported} ==
               Availability.validate_bookable(Map.put(fixed(), "is_chargeable", value))
    end

    for details <- [
          Map.delete(fixed(), "facility_rate"),
          Map.put(fixed(), "facility_rate", nil),
          Map.put(fixed(), "facility_rate", "0oops"),
          Map.put(fixed(), "facility_rate", -1),
          Map.put(fixed(), "facility_rate", 10),
          Map.put(fixed(), "is_chargeable", "maybe"),
          fixed() |> Map.put("is_chargeable", false) |> Map.put("facility_rate", "broken")
        ] do
      assert {:error, _} = Availability.validate_bookable(details)
    end
  end
end
