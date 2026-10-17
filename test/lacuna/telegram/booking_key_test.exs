defmodule Lacuna.Telegram.BookingKeyTest do
  use ExUnit.Case, async: true

  alias Lacuna.Slot
  alias Lacuna.Telegram.{BookingKey, Views}

  defp slot do
    %Slot{
      facility_id: String.duplicate("A", 64),
      facility_name: "Synthetic Court A",
      date: ~D[2099-10-11],
      start_time: ~T[19:00:00],
      end_time: ~T[20:00:00]
    }
  end

  test "court picker and alert buttons fit Telegram's callback limit with real-length IDs" do
    for opts <- [[], [show_time: false]] do
      button = Views.booking_button(slot(), {:ok, []}, opts)
      assert byte_size(button.callback_data) <= 64
      assert "book:" <> key = button.callback_data
      courts = [%{id: slot().facility_id}, %{id: String.duplicate("B", 64)}]
      assert {:ok, id, ~D[2099-10-11], ~T[19:00:00]} = BookingKey.decode(key, {:ok, courts})
      assert id == slot().facility_id

      assert BookingKey.decode(key, {:ok, Enum.reverse(courts)}) ==
               {:ok, id, ~D[2099-10-11], ~T[19:00:00]}
    end
  end

  test "legacy buttons resolve only an exact configured court" do
    courts = [%{id: slot().facility_id}]

    assert {:ok, id, ~D[2099-10-11], ~T[19:00:00]} =
             BookingKey.decode(Slot.key(slot()), {:ok, courts})

    assert id == slot().facility_id
    assert {:error, :invalid_slot_key} = BookingKey.decode(Slot.key(slot()), {:ok, []})
  end

  test "unknown, ambiguous, malformed and unavailable-catalog keys never resolve" do
    key = BookingKey.encode(slot())
    court = %{id: slot().facility_id}
    assert {:error, :invalid_slot_key} = BookingKey.decode(key, {:ok, []})
    assert {:error, :invalid_slot_key} = BookingKey.decode(key, {:ok, [court, court]})
    assert {:error, :invalid_slot_key} = BookingKey.decode(key, {:error, :not_yet_discovered})

    for bad <- [
          "v1:unknown|2099-10-11|19:00:00",
          "missing",
          key <> "|extra",
          String.replace(key, "2099-10-11", "2099-02-30"),
          String.replace(key, "19:00:00", "25:00:00")
        ] do
      assert {:error, :invalid_slot_key} = BookingKey.decode(bad, {:ok, [court]})
    end
  end
end
