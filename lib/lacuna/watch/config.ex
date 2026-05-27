defmodule Lacuna.Watch.Config do
  @moduledoc """
  In-memory single-watch configuration. The poller only runs while a
  watch is `active?`. Default state at boot = inactive.

  Configuration set via the `/watch` interactive flow:

    * `date_preset` — `nil | :today | :tomorrow | :weekend`
    * `weekdays`  — `[]` (any) or `["Sat","Sun"]`
    * `window`    — `"morning" | "afternoon" | "evening" | "any"`
    * `expires_at` — optional; nil = until manually disabled
    * `stop_before_start_minutes` — optional per-slot cutoff
    * `auto_book?` — whether matching opened slots should be booked automatically

  This GenServer is intentionally lightweight: a single map, no
  persistence. A bot restart resets everything to inactive — fine for
  the MVP and avoids the user being surprised by leftover watches.
  """

  use GenServer

  alias Lacuna.Slot

  @type window :: :morning | :afternoon | :evening | :any
  @type t :: %__MODULE__{
          active?: boolean(),
          date_preset: :today | :tomorrow | :weekend | nil,
          weekdays: [String.t()],
          window: window(),
          expires_at: DateTime.t() | nil,
          stop_before_start_minutes: non_neg_integer() | nil,
          auto_book?: boolean()
        }

  defstruct active?: false,
            date_preset: nil,
            weekdays: [],
            window: :any,
            expires_at: nil,
            stop_before_start_minutes: nil,
            auto_book?: false

  @default_windows %{
    morning: {6, 12, "Morning"},
    afternoon: {12, 18, "Afternoon"},
    evening: {18, 22, "Evening"},
    any: {0, 24, "Any time"}
  }

  ## Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)

  def enable, do: GenServer.call(__MODULE__, :enable)
  def disable, do: GenServer.call(__MODULE__, :disable)

  def set_window(window) when window in [:morning, :afternoon, :evening, :any],
    do: GenServer.call(__MODULE__, {:set_window, window})

  def set_date_preset(preset) when preset in [:today, :tomorrow, :weekend, nil],
    do: GenServer.call(__MODULE__, {:set_date_preset, preset})

  def set_weekdays(list) when is_list(list),
    do: GenServer.call(__MODULE__, {:set_weekdays, list})

  def set_expires(at_or_nil), do: GenServer.call(__MODULE__, {:set_expires, at_or_nil})

  def set_stop_before_start(minutes_or_nil),
    do: GenServer.call(__MODULE__, {:set_stop_before_start, minutes_or_nil})

  def set_auto_book(enabled?) when is_boolean(enabled?),
    do: GenServer.call(__MODULE__, {:set_auto_book, enabled?})

  @doc "True if a watch is currently active and not expired."
  @spec active?() :: boolean()
  def active? do
    case get() do
      %{active?: false} ->
        false

      %{active?: true, expires_at: nil} ->
        true

      %{active?: true, expires_at: %DateTime{} = exp} ->
        DateTime.compare(DateTime.utc_now(), exp) == :lt
    end
  end

  @doc "Return the human label for a window key."
  def window_label(key), do: elem(Map.fetch!(windows(), key), 2)

  @doc "Return {start_hour, end_hour} for a window key."
  def window_range(key) do
    {lo, hi, _} = Map.fetch!(windows(), key)
    {lo, hi}
  end

  def windows do
    :lacuna
    |> Application.get_env(:watch_windows, %{})
    |> normalize_windows()
  end

  @doc "Return the currently selected watch weekdays. Empty means any day."
  @spec weekdays() :: [String.t()]
  def weekdays, do: get().weekdays

  @doc "Test whether a date can match the active watch date filter."
  @spec date_matches_weekday?(Date.t()) :: boolean()
  def date_matches_weekday?(%Date{} = date), do: date_ok?(date, get())

  @doc "Test whether a slot matches the active watch."
  @spec matches?(Slot.t()) :: boolean()
  def matches?(%Slot{} = slot) do
    cfg = get()

    cond do
      not cfg.active? -> false
      expired?(cfg) -> false
      not date_ok?(slot.date, cfg) -> false
      not window_ok?(slot, cfg.window) -> false
      past_stop_before_start?(slot, cfg.stop_before_start_minutes) -> false
      true -> true
    end
  end

  ## Internal

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: %DateTime{} = at}),
    do: DateTime.compare(DateTime.utc_now(), at) != :lt

  defp date_ok?(date, %{date_preset: :today}),
    do: Date.compare(date, Lacuna.Clock.local_today()) == :eq

  defp date_ok?(date, %{date_preset: :tomorrow}),
    do: Date.compare(date, Date.add(Lacuna.Clock.local_today(), 1)) == :eq

  defp date_ok?(date, %{date_preset: :weekend}), do: Date.day_of_week(date) in [6, 7]
  defp date_ok?(date, %{weekdays: weekdays}), do: date_weekday_ok?(date, weekdays)

  defp date_weekday_ok?(_date, []), do: true

  defp date_weekday_ok?(%Date{} = date, list) do
    short = day_short(Date.day_of_week(date))
    Enum.any?(list, fn x -> String.downcase(String.slice(x, 0, 3)) == String.downcase(short) end)
  end

  defp window_ok?(%Slot{start_time: %Time{hour: h}, end_time: et}, window) do
    {lo, hi, _} = Map.fetch!(windows(), window)
    end_hour = if et.minute == 0, do: et.hour, else: et.hour + 1
    h >= lo and end_hour <= hi
  end

  defp normalize_windows(overrides) when is_map(overrides) do
    Map.merge(@default_windows, overrides, fn key, _default, override ->
      normalize_window!(key, override)
    end)
  end

  defp normalize_window!(_key, {lo, hi, label})
       when is_integer(lo) and is_integer(hi) and is_binary(label) and lo >= 0 and hi <= 24 and
              lo < hi,
       do: {lo, hi, label}

  defp normalize_window!(key, value),
    do: raise(ArgumentError, "invalid watch window #{inspect(key)}: #{inspect(value)}")

  defp past_stop_before_start?(_slot, nil), do: false

  defp past_stop_before_start?(%Slot{date: date, start_time: time}, minutes)
       when is_integer(minutes) do
    slot_at_utc =
      date
      |> NaiveDateTime.new!(time)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.add(-4 * 3600, :second)

    cutoff = DateTime.add(slot_at_utc, -minutes * 60, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) != :lt
  end

  defp day_short(1), do: "Mon"
  defp day_short(2), do: "Tue"
  defp day_short(3), do: "Wed"
  defp day_short(4), do: "Thu"
  defp day_short(5), do: "Fri"
  defp day_short(6), do: "Sat"
  defp day_short(7), do: "Sun"

  ## GenServer

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, s), do: {:reply, s, s}

  def handle_call(:enable, _from, s) do
    new = %{s | active?: true}
    notify(new)
    {:reply, new, new}
  end

  def handle_call(:disable, _from, s) do
    new = %{s | active?: false, expires_at: nil, auto_book?: false}
    notify(new)
    {:reply, new, new}
  end

  def handle_call({:set_window, w}, _from, s), do: {:reply, %{s | window: w}, %{s | window: w}}

  def handle_call({:set_date_preset, preset}, _from, s),
    do:
      {:reply, %{s | date_preset: preset, weekdays: []}, %{s | date_preset: preset, weekdays: []}}

  def handle_call({:set_weekdays, list}, _from, s),
    do: {:reply, %{s | date_preset: nil, weekdays: list}, %{s | date_preset: nil, weekdays: list}}

  def handle_call({:set_expires, at}, _from, s),
    do: {:reply, %{s | expires_at: at}, %{s | expires_at: at}}

  def handle_call({:set_stop_before_start, minutes}, _from, s),
    do:
      {:reply, %{s | stop_before_start_minutes: minutes},
       %{s | stop_before_start_minutes: minutes}}

  def handle_call({:set_auto_book, enabled?}, _from, s),
    do: {:reply, %{s | auto_book?: enabled?}, %{s | auto_book?: enabled?}}

  defp notify(_state) do
    # Wake the poller if a watch was just enabled / disabled. Best-effort.
    Process.whereis(Lacuna.Watcher.Poller)
    |> case do
      pid when is_pid(pid) -> send(pid, :watch_changed)
      _ -> :ok
    end
  end
end
