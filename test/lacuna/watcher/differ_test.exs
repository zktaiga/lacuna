defmodule Lacuna.Watcher.DifferTest do
  use ExUnit.Case, async: true

  alias Lacuna.{Slot, Watcher.Differ, Watcher.State}

  defp slot(id, hour) do
    %Slot{
      facility_id: id,
      facility_name: "f #{id}",
      date: ~D[2026-05-08],
      start_time: Time.new!(hour, 0, 0),
      end_time: Time.new!(hour + 1, 0, 0)
    }
  end

  test "first poll: every slot counts as opened" do
    now = State.from_slots([slot("a", 18), slot("b", 19)])
    diff = Differ.diff(%{}, now)

    assert length(diff.opened) == 2
    assert diff.closed == []
  end

  test "stable poll: no opens, no closes" do
    snap = State.from_slots([slot("a", 18), slot("b", 19)])
    diff = Differ.diff(snap, snap)

    assert diff.opened == []
    assert diff.closed == []
  end

  test "cancellation appears as opened in next snapshot" do
    prev = State.from_slots([slot("a", 18)])
    now = State.from_slots([slot("a", 18), slot("a", 19)])

    diff = Differ.diff(prev, now)
    assert [%Slot{start_time: ~T[19:00:00]}] = diff.opened
    assert diff.closed == []
  end

  test "filled slot disappears" do
    prev = State.from_slots([slot("a", 18), slot("a", 19)])
    now = State.from_slots([slot("a", 18)])

    diff = Differ.diff(prev, now)
    assert diff.opened == []
    assert [%Slot{start_time: ~T[19:00:00]}] = diff.closed
  end
end
