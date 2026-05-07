defmodule Lacuna.Watch.ConfigTest do
  use ExUnit.Case, async: false

  alias Lacuna.{Slot, Watch.Config}

  setup do
    start_supervised!(Config)
    :ok
  end

  test "evening starts at 18:00 by default" do
    assert Config.window_range(:evening) == {18, 22}
  end

  test "auto-book is opt-in and disabling a watch resets it" do
    refute Config.get().auto_book?

    Config.set_auto_book(true)
    assert Config.get().auto_book?

    Config.disable()
    refute Config.get().auto_book?
  end

  test "date presets override weekday matching" do
    today = Lacuna.Clock.local_today()
    tomorrow = Date.add(today, 1)

    Config.enable()
    Config.set_date_preset(:today)

    assert Config.matches?(slot_on(today))
    refute Config.matches?(slot_on(tomorrow))
  end

  test "weekday selection clears date presets" do
    Config.set_date_preset(:today)
    Config.set_weekdays(["Thu"])

    cfg = Config.get()
    assert cfg.date_preset == nil
    assert cfg.weekdays == ["Thu"]
  end

  test "stop-before-start cutoff filters slots that are too close" do
    slot = slot_at(DateTime.utc_now() |> DateTime.add(25 * 60, :second))

    Config.enable()
    Config.set_stop_before_start(nil)
    assert Config.matches?(slot)

    Config.set_stop_before_start(30)
    refute Config.matches?(slot)
  end

  defp slot_on(%Date{} = date) do
    %Slot{
      facility_id: "facility-1",
      facility_name: "Court 1",
      date: date,
      start_time: ~T[18:00:00],
      end_time: ~T[19:00:00]
    }
  end

  defp slot_at(%DateTime{} = utc) do
    dubai = DateTime.add(utc, 4 * 3600, :second)

    %Slot{
      facility_id: "facility-1",
      facility_name: "Court 1",
      date: DateTime.to_date(dubai),
      start_time: DateTime.to_time(dubai) |> Time.truncate(:second),
      end_time:
        dubai |> DateTime.add(3600, :second) |> DateTime.to_time() |> Time.truncate(:second)
    }
  end
end
