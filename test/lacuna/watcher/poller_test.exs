defmodule Lacuna.Watcher.PollerTest do
  use ExUnit.Case, async: false

  alias Lacuna.{Watch.Config, Watcher.Poller}

  setup do
    start_supervised!(Config)
    :ok
  end

  test "poll planning skips dates outside the watch weekday filter" do
    Config.set_weekdays(["Thu"])

    days = Poller.planned_dates(~D[2026-05-07], 7)

    assert days == [~D[2026-05-07]]
  end

  test "poll planning keeps every date when any day is selected" do
    Config.set_weekdays([])

    days = Poller.planned_dates(~D[2026-05-07], 3)

    assert days == [~D[2026-05-07], ~D[2026-05-08], ~D[2026-05-09]]
  end
end
