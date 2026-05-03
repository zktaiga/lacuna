defmodule Lacuna.Backend.AvailabilityTest do
  use ExUnit.Case, async: true

  alias Lacuna.Backend.Availability

  test "open slots = working hours grid minus booked, fixed-slot mode (map shape)" do
    details = %{
      "facility_id" => "court-a",
      "facility_name" => "Court A",
      "is_facility_fixed_slot_based" => "1",
      "fixed_time_slots" => %{
        "369" => "18:00 - 19:00",
        "370" => "19:00 - 20:00",
        "371" => "20:00 - 21:00"
      },
      "booked_slots_on_date" => [
        %{"start_time" => "19:00", "duration" => 60}
      ],
      "blocked_week_days" => [],
      "week_days" => []
    }

    open = Availability.open_slots(details, ~D[2026-05-08])
    times = Enum.map(open, & &1.start_time) |> Enum.sort(Time)
    assert times == [~T[18:00:00], ~T[20:00:00]]

    # Slot id is propagated for the booking call
    eighteen = Enum.find(open, &(&1.start_time == ~T[18:00:00]))
    assert eighteen.slot_id == "369"
  end

  test "windowed mode enumerates the grid by booking_hrs" do
    details = %{
      "facility_id" => "court-a",
      "facility_name" => "Court A",
      "is_facility_fixed_slot_based" => false,
      "start_hour" => 18,
      "start_min" => 0,
      "end_hour" => 21,
      "end_min" => 0,
      "booking_hrs" => 1,
      "booked_slots_on_date" => [],
      "blocked_week_days" => [],
      "week_days" => []
    }

    open = Availability.open_slots(details, ~D[2026-05-08])
    assert Enum.map(open, & &1.start_time) == [~T[18:00:00], ~T[19:00:00], ~T[20:00:00]]
  end

  test "blocked weekdays produce empty list" do
    details = %{
      "facility_id" => "court-a",
      "is_facility_fixed_slot_based" => false,
      "start_hour" => 18,
      "start_min" => 0,
      "end_hour" => 21,
      "end_min" => 0,
      "booking_hrs" => 1,
      "booked_slots_on_date" => [],
      "blocked_week_days" => ["Fri"],
      "week_days" => []
    }

    # 2026-05-08 is a Friday
    assert Availability.open_slots(details, ~D[2026-05-08]) == []
  end
end
