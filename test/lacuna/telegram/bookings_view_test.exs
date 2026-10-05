defmodule Lacuna.Telegram.BookingsViewTest do
  use ExUnit.Case, async: true
  alias Lacuna.Telegram.BookingsView

  test "list buttons are chronological and open details rather than cancellation" do
    early = booking("early", "31-Oct-2099", "Neighborhood 1 - Padel Court")
    late = booking("late", "01-Nov-2099", "Neighborhood 3  -Padel Court 2")
    markup = BookingsView.list_keyboard([late, early])
    assert [[first], [second], [_nav]] = markup.inline_keyboard
    assert first.callback_data == "bk:v:early"
    assert second.callback_data == "bk:v:late"
    assert first.text =~ "31 Oct · 19:00 · Neighborhood 1"
    assert second.text =~ "1 Nov · 19:00 · Neighborhood 3 / Court 2"
    refute BookingsView.list_text([early, late]) =~ "BKN123"
    assert BookingsView.list_text([early, late]) =~ "2 upcoming"
  end

  test "details show court, full time range and reference; today's button says Today" do
    today = Lacuna.Clock.local_today()
    b = booking("today", Date.to_iso8601(today), "Neighborhood 2 - Padel Court")
    assert [[button], [_nav]] = BookingsView.list_keyboard([b]).inline_keyboard
    assert button.text == "Today · 19:00 · Neighborhood 2"
    assert BookingsView.details_text(b) =~ "*Neighborhood 2*"
    assert BookingsView.details_text(b) =~ "19:00–20:00"
    assert BookingsView.details_text(b) =~ "Reference: `BKN123`"
  end

  defp booking(id, date, court),
    do: %{
      "booking_id" => id,
      "booking_no" => "BKN123",
      "facility_name" => court,
      "start_date" => date,
      "start_time" => "19:00",
      "end_time" => "20:00",
      "type" => "upcoming_bookings",
      "status" => "Booked"
    }
end
