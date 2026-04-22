defmodule Lacuna.Clock do
  @moduledoc """
  Tiny timezone helper. The configured community timezone is Dubai
  (UTC+4, no DST), so "today" in the bot's mind has to be Dubai-local,
  not UTC.

  Hardcoding the offset is fine here: Gulf Standard Time is a stable
  +04:00 year-round and we don't ship to other regions. If/when this
  changes, replace with `:tz` lib lookups via the `community_timezone`
  field returned by the dashboard endpoint.
  """

  @offset_hours 4

  @spec local_today() :: Date.t()
  def local_today do
    DateTime.utc_now()
    |> DateTime.add(@offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  @spec local_now() :: NaiveDateTime.t()
  def local_now do
    DateTime.utc_now()
    |> DateTime.add(@offset_hours * 3600, :second)
    |> DateTime.to_naive()
  end

  @spec local_time() :: Time.t()
  def local_time, do: local_now() |> NaiveDateTime.to_time()
end
