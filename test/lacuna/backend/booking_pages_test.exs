defmodule Lacuna.Backend.BookingPagesTest do
  use ExUnit.Case, async: true
  alias Lacuna.Backend.BookingPages

  test "follows returned upcoming offsets and preserves all active records" do
    parent = self()

    fetch = fn offsets ->
      send(parent, {:offsets, offsets})

      case offsets["upcoming_offset"] do
        0 -> {:ok, page([booking("a")], 2, 15)}
        2 -> {:ok, page([booking("b")], -1, 30)}
      end
    end

    assert {:ok, %{"my_bookings" => %{"Upcoming bookings" => rows}}} = BookingPages.collect(fetch)
    assert Enum.map(rows, & &1["booking_id"]) == ["a", "b"]
    assert_receive {:offsets, %{"upcoming_offset" => 0, "past_offset" => 0}}
    assert_receive {:offsets, %{"upcoming_offset" => 2, "past_offset" => 15}}
    refute_receive {:offsets, _}
  end

  test "stops at exhausted upcoming inventory without traversing unrelated history" do
    assert {:ok, _} =
             BookingPages.collect(fn offsets ->
               assert offsets == %{"upcoming_offset" => 0, "past_offset" => 0}
               {:ok, page([], -1, 15)}
             end)
  end

  test "missing malformed or nonadvancing pagination cannot establish completeness" do
    for response <- [
          Map.delete(page([], -1), "offset_details"),
          Map.put(page([], -1), "offset_details", nil),
          page([], "not-an-offset"),
          page([], 0),
          page([], -2)
        ] do
      assert {:error, :incomplete_bookings} = BookingPages.collect(fn _ -> {:ok, response} end)
    end
  end

  test "later page failure does not return a partial success" do
    assert {:error, :unavailable} =
             BookingPages.collect(fn offsets ->
               if offsets["upcoming_offset"] == 0,
                 do: {:ok, page([booking("a")], 1)},
                 else: {:error, :unavailable}
             end)
  end

  test "duplicate identical records are deduplicated but contradictions fail closed" do
    for changed <- [false, true] do
      second = if changed, do: Map.put(booking("a"), "status", "cancelled"), else: booking("a")

      result =
        BookingPages.collect(fn offsets ->
          if offsets["upcoming_offset"] == 0,
            do: {:ok, page([booking("a")], 1)},
            else: {:ok, page([second], -1)}
        end)

      if changed,
        do: assert(result == {:error, :inconsistent_bookings}),
        else: assert(match?({:ok, %{"my_bookings" => %{"Upcoming bookings" => [_]}}}, result))
    end
  end

  test "malformed records and unbounded pagination fail closed" do
    assert {:error, :invalid_bookings} = BookingPages.collect(fn _ -> {:ok, page([%{}], -1)} end)

    assert {:error, :incomplete_bookings} =
             BookingPages.collect(fn offsets ->
               {:ok, page([], offsets["upcoming_offset"] + 1)}
             end)
  end

  for field <- ~w(booking_id facility_id type status start_date start_time end_time) do
    test "rejects a row missing #{field}" do
      row = Map.delete(booking("a"), unquote(field))

      assert {:error, :invalid_bookings} =
               BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)
    end
  end

  for {field, values} <- [
        {"booking_id", [nil, "", "  ", " a ", false, %{}]},
        {"facility_id", [nil, "", "  ", " court-a ", false, %{}]},
        {"type", [nil, "", "unknown", "Upcoming bookings", false]},
        {"status", [nil, "", " \t\n", false, 1, %{}]},
        {"start_date",
         [nil, "", "2026-02-29", "31-Apr-2026", "01-Foo-2026", "2026-13-01", "tomorrow"]},
        {"start_time",
         [nil, "", "9:00", "24:00", "10:60", "10:00:60", "10:00junk", " 10:00", "10:00:00Z"]},
        {"end_time", [nil, "", "10:00", "09:00", "24:00", "11:00:60", "11:00junk", "11:00:00.5"]}
      ],
      value <- values do
    test "rejects invalid #{field} #{inspect(value)}" do
      row = Map.put(booking("a"), unquote(field), unquote(Macro.escape(value)))

      assert {:error, :invalid_bookings} =
               BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)
    end
  end

  test "accepts real named-month rows, supported date/time aliases and approval statuses unchanged" do
    for date <- ["2028-02-29", "29-Feb-2028", "29-feb-2028", "29/02/2028", "29-02-2028"],
        status <- ["Booked", "Cancelled", "Pending Approval", "Awaiting committee review"],
        type <- ["upcoming_bookings", "past_bookings"] do
      row = booking("a") |> Map.merge(%{"start_date" => date, "status" => status, "type" => type})
      assert {:ok, data} = BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)
      assert data["my_bookings"]["Upcoming bookings"] == [row]
    end

    row =
      booking(123)
      |> Map.drop(~w(start_date start_time end_time))
      |> Map.merge(%{
        "facility_id" => 456,
        "booking_date" => "2028-02-29",
        "booking_start_time" => "10:00:00",
        "booking_end_time" => "11:00:00"
      })

    assert {:ok, _} = BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)

    row =
      row
      |> Map.drop(~w(booking_date booking_start_time booking_end_time))
      |> Map.merge(%{"date" => "2028-02-29", "from_time" => "10:00", "to_time" => "11:00"})

    assert {:ok, _} = BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)
  end

  test "invalid records on later pages cannot become a partial complete inventory" do
    assert {:error, :invalid_bookings} =
             BookingPages.collect(fn offsets ->
               if offsets["upcoming_offset"] == 0,
                 do: {:ok, page([booking("a")], 1)},
                 else: {:ok, page([Map.delete(booking("b"), "type")], -1)}
             end)
  end

  test "validates cancelled and past rows as well as active rows before declaring completeness" do
    for override <- [%{"status" => "Cancelled"}, %{"type" => "past_bookings"}] do
      row = booking("a") |> Map.merge(override) |> Map.delete("facility_id")

      assert {:error, :invalid_bookings} =
               BookingPages.collect(fn _ -> {:ok, page([row], -1)} end)
    end
  end

  test "a booking id alone is not a classifiable booking" do
    assert {:error, :invalid_bookings} =
             BookingPages.collect(fn _ -> {:ok, page([%{"booking_id" => "a"}], -1)} end)
  end

  defp booking(id),
    do: %{
      "booking_id" => id,
      "facility_id" => "court-a",
      "facility_name" => "Court A",
      "type" => "upcoming_bookings",
      "status" => "Booked",
      "start_date" => "17-Oct-2026",
      "start_time" => "10:00",
      "end_time" => "11:00"
    }

  defp page(rows, upcoming, past \\ -1),
    do: %{
      "my_bookings" => %{"Upcoming bookings" => rows},
      "offset_details" => %{"upcoming_offset" => upcoming, "past_offset" => past}
    }
end
