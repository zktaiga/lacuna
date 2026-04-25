defmodule Lacuna.Plugins.PrefMatcher do
  @moduledoc """
  Default Matcher implementation: applies the rules in `prefs.toml`'s
  `[match]` table — court whitelist, weekday window, hour window.
  """

  @behaviour Lacuna.Behaviours.Matcher
  alias Lacuna.Slot

  @impl true
  def matches?(%Slot{} = slot, %{match: m}) do
    court_ok?(slot, m.court_ids) and
      weekday_ok?(slot, m.weekdays) and
      hours_ok?(slot, m.start_hour, m.end_hour)
  end

  defp court_ok?(_slot, []), do: true

  defp court_ok?(%Slot{facility_id: id, facility_name: name}, list),
    do:
      Enum.any?(list, fn pat ->
        id == pat or String.contains?(String.downcase(name), String.downcase(pat))
      end)

  defp weekday_ok?(_slot, []), do: true

  defp weekday_ok?(%Slot{date: d}, list) do
    short = day_short(Date.day_of_week(d))
    Enum.any?(list, fn x -> String.downcase(String.slice(x, 0, 3)) == String.downcase(short) end)
  end

  defp hours_ok?(%Slot{start_time: %Time{} = st, end_time: %Time{} = et}, lo, hi) do
    lo_t = Time.new!(lo, 0, 0)
    hi_t = Time.new!(hi, 0, 0)

    Time.compare(st, lo_t) in [:gt, :eq] and Time.compare(et, hi_t) in [:lt, :eq]
  end

  defp day_short(1), do: "Mon"
  defp day_short(2), do: "Tue"
  defp day_short(3), do: "Wed"
  defp day_short(4), do: "Thu"
  defp day_short(5), do: "Fri"
  defp day_short(6), do: "Sat"
  defp day_short(7), do: "Sun"
end
