defmodule Lacuna.Watcher.State do
  @moduledoc """
  Wraps the current snapshot of open slots, keyed by stable Slot.key/1.
  """

  alias Lacuna.Slot

  @type t :: %{String.t() => Slot.t()}

  @spec from_slots([Slot.t()]) :: t()
  def from_slots(slots), do: Map.new(slots, fn s -> {Slot.key(s), s} end)

  @spec empty() :: t()
  def empty, do: %{}
end
