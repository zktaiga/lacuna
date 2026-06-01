defmodule Lacuna.Watcher.PollerTest do
  use ExUnit.Case, async: false

  alias Lacuna.Hunts.Hunt
  alias Lacuna.Watcher.Poller

  test "poll planning skips dates outside hunt weekday filters" do
    hunt = Hunt.new(%{weekdays: ["Thu"]})

    days = Poller.planned_dates(~D[2026-05-07], 7, [hunt])

    assert days == [~D[2026-05-07]]
  end

  test "poll planning merges multiple hunt weekday filters" do
    wed = Hunt.new(%{weekdays: ["Wed"]})
    thu = Hunt.new(%{weekdays: ["Thu"]})

    days = Poller.planned_dates(~D[2026-05-06], 7, [wed, thu])

    assert days == [~D[2026-05-06], ~D[2026-05-07]]
  end

  test "poll planning keeps every date when any active hunt has no day filter" do
    hunt = Hunt.new(%{weekdays: []})

    days = Poller.planned_dates(~D[2026-05-07], 3, [hunt])

    assert days == [~D[2026-05-07], ~D[2026-05-08], ~D[2026-05-09]]
  end
end
