defmodule Lacuna.Slot do
  @moduledoc """
  A single bookable time window on one court for one date.

  `start_time` and `end_time` are wall-clock times in the court's local
  timezone (no TZ conversion happens in the bot — the backend already
  speaks local time). `duration_minutes` is redundant with
  `end_time - start_time` but kept because the backend exposes both.
  """

  @enforce_keys [:facility_id, :facility_name, :date, :start_time, :end_time]
  defstruct [
    :facility_id,
    :facility_name,
    :date,
    :start_time,
    :end_time,
    :duration_minutes,
    :rate,
    :rate_type,
    :slot_id,
    fee_aed: 0
  ]

  @type t :: %__MODULE__{
          facility_id: String.t(),
          facility_name: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          duration_minutes: pos_integer() | nil,
          rate: number() | nil,
          rate_type: String.t() | nil,
          slot_id: String.t() | nil,
          fee_aed: number()
        }

  @doc "Stable string key — useful as a Map/Set key for diffing snapshots."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{facility_id: f, date: d, start_time: t}) do
    "#{f}|#{Date.to_iso8601(d)}|#{Time.to_iso8601(t)}"
  end
end
