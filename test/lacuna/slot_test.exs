defmodule Lacuna.SlotTest do
  use ExUnit.Case, async: true

  alias Lacuna.Slot

  test "key/1 is stable across struct equality" do
    s = %Slot{
      facility_id: "abc",
      facility_name: "Court A",
      date: ~D[2026-05-08],
      start_time: ~T[18:00:00],
      end_time: ~T[19:00:00]
    }

    assert Slot.key(s) == "abc|2026-05-08|18:00:00"
  end
end
