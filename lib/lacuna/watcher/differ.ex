defmodule Lacuna.Watcher.Differ do
  @moduledoc """
  Pure: given two snapshots (`prev`, `now`), classify each slot as
  opened / still-open / closed.

  Used by the poller to decide what to publish on the event bus.
  """

  alias Lacuna.{Slot, Watcher.State}

  @spec diff(State.t(), State.t()) :: %{opened: [Slot.t()], closed: [Slot.t()]}
  def diff(prev, now) when is_map(prev) and is_map(now) do
    opened_keys = MapSet.difference(keyset(now), keyset(prev))
    closed_keys = MapSet.difference(keyset(prev), keyset(now))

    %{
      opened: Enum.map(opened_keys, &Map.fetch!(now, &1)),
      closed: Enum.map(closed_keys, &Map.fetch!(prev, &1))
    }
  end

  defp keyset(m), do: m |> Map.keys() |> MapSet.new()
end
