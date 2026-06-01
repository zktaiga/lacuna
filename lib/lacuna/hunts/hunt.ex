defmodule Lacuna.Hunts.Hunt do
  @moduledoc "A persisted standing slot hunt."

  alias Lacuna.Slot

  @weekday_keys ~w(Mon Tue Wed Thu Fri Sat Sun)

  defstruct [
    :id,
    :name,
    active?: true,
    weekdays: [],
    times: [],
    mode: :alert_only,
    after_match: :stop_on_first,
    blocked_reason: nil,
    created_at: nil,
    updated_at: nil
  ]

  @type mode :: :alert_only | :auto_book
  @type after_match :: :stop_on_first | :continue
  @type t :: %__MODULE__{}

  def new(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    id = Map.get(attrs, :id) || new_id()

    %__MODULE__{
      id: id,
      name: Map.get(attrs, :name) || "Hunt #{String.slice(id, -4, 4)}",
      active?: Map.get(attrs, :active?, true),
      weekdays: Map.get(attrs, :weekdays, []),
      times: Map.get(attrs, :times, []),
      mode: Map.get(attrs, :mode, :alert_only),
      after_match: Map.get(attrs, :after_match, :stop_on_first),
      blocked_reason: Map.get(attrs, :blocked_reason),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    }
  end

  def active?(%__MODULE__{active?: active?}), do: active?

  def matches?(%__MODULE__{active?: false}, %Slot{}), do: false

  def matches?(%__MODULE__{} = hunt, %Slot{} = slot) do
    weekday_matches?(hunt.weekdays, slot.date) and time_matches?(hunt.times, slot.start_time)
  end

  def to_json(%__MODULE__{} = hunt) do
    %{
      id: hunt.id,
      name: hunt.name,
      active?: hunt.active?,
      weekdays: hunt.weekdays,
      times: Enum.map(hunt.times, &Time.to_iso8601/1),
      mode: Atom.to_string(hunt.mode),
      after_match: Atom.to_string(hunt.after_match),
      blocked_reason: hunt.blocked_reason,
      created_at: hunt.created_at && DateTime.to_iso8601(hunt.created_at),
      updated_at: hunt.updated_at && DateTime.to_iso8601(hunt.updated_at)
    }
  end

  def from_json(%{} = data) do
    new(%{
      id: data["id"] || data[:id],
      name: data["name"] || data[:name],
      active?: Map.get(data, "active?", Map.get(data, :active?, true)),
      weekdays: data["weekdays"] || data[:weekdays] || [],
      times: parse_times(data["times"] || data[:times] || []),
      mode: parse_atom(data["mode"] || data[:mode], :alert_only),
      after_match: parse_atom(data["after_match"] || data[:after_match], :stop_on_first),
      blocked_reason: data["blocked_reason"] || data[:blocked_reason],
      created_at: parse_datetime(data["created_at"] || data[:created_at]),
      updated_at: parse_datetime(data["updated_at"] || data[:updated_at])
    })
  end

  def touch(%__MODULE__{} = hunt),
    do: %{hunt | updated_at: DateTime.utc_now() |> DateTime.truncate(:second)}

  def weekday_keys, do: @weekday_keys

  defp weekday_matches?([], _date), do: true

  defp weekday_matches?(weekdays, %Date{} = date) do
    day = Enum.at(@weekday_keys, Date.day_of_week(date) - 1)
    day in weekdays
  end

  defp time_matches?([], _time), do: true

  defp time_matches?(times, %Time{} = time) do
    time = Time.truncate(time, :second)
    Enum.any?(times, &(Time.compare(&1, time) == :eq))
  end

  defp parse_times(values) do
    values
    |> Enum.map(&parse_time/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_time(%Time{} = time), do: Time.truncate(time, :second)

  defp parse_time(value) when is_binary(value) do
    value
    |> pad_time_seconds()
    |> Time.from_iso8601()
    |> case do
      {:ok, time} -> Time.truncate(time, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp pad_time_seconds(<<_::binary-size(5)>> = value), do: value <> ":00"
  defp pad_time_seconds(value), do: value

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> default
  end

  defp parse_atom(value, _default) when is_atom(value), do: value
  defp parse_atom(_, default), do: default

  defp new_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
