defmodule Lacuna.Plugins.PrefMatcherTest do
  use ExUnit.Case, async: true

  alias Lacuna.{Slot, Plugins.PrefMatcher}

  defp slot(opts \\ []) do
    %Slot{
      facility_id: Keyword.get(opts, :id, "court-a"),
      facility_name: Keyword.get(opts, :name, "Court A"),
      date: Keyword.get(opts, :date, ~D[2026-05-09]),
      start_time: Keyword.get(opts, :start, ~T[18:00:00]),
      end_time: Keyword.get(opts, :end_, ~T[19:00:00])
    }
  end

  defp prefs(overrides \\ %{}) do
    base = %{
      match: %{
        category: "",
        weekdays: [],
        start_hour: 0,
        end_hour: 23,
        court_ids: []
      }
    }

    %{base | match: Map.merge(base.match, overrides)}
  end

  test "empty prefs match everything" do
    assert PrefMatcher.matches?(slot(), prefs())
  end

  test "court whitelist matches by id" do
    refute PrefMatcher.matches?(slot(), prefs(%{court_ids: ["court-b"]}))
    assert PrefMatcher.matches?(slot(), prefs(%{court_ids: ["court-a"]}))
  end

  test "court whitelist matches by name fragment" do
    assert PrefMatcher.matches?(slot(name: "Court Alpha 1"), prefs(%{court_ids: ["alpha"]}))
  end

  test "weekday filter" do
    sat = slot(date: ~D[2026-05-09])
    sun = slot(date: ~D[2026-05-10])
    p = prefs(%{weekdays: ["Sat"]})

    assert PrefMatcher.matches?(sat, p)
    refute PrefMatcher.matches?(sun, p)
  end

  test "hour window inclusive on the edges" do
    # 18-19 within 17-22 OK
    assert PrefMatcher.matches?(
             slot(start: ~T[18:00:00], end_: ~T[19:00:00]),
             prefs(%{start_hour: 17, end_hour: 22})
           )

    # 22-23 out of 17-22
    refute PrefMatcher.matches?(
             slot(start: ~T[22:00:00], end_: ~T[23:00:00]),
             prefs(%{start_hour: 17, end_hour: 22})
           )
  end
end
