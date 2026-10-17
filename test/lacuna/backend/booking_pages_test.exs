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

  defp booking(id), do: %{"booking_id" => id, "type" => "upcoming_bookings", "status" => "Booked"}

  defp page(rows, upcoming, past \\ -1),
    do: %{
      "my_bookings" => %{"Upcoming bookings" => rows},
      "offset_details" => %{"upcoming_offset" => upcoming, "past_offset" => past}
    }
end
