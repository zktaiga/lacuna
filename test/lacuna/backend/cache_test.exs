defmodule Lacuna.Backend.CacheTest do
  use ExUnit.Case, async: false

  alias Lacuna.Backend.Cache

  setup do
    start_supervised!(Cache)
    :ok
  end

  test "stores values until ttl expires" do
    Cache.put(:key, :value, 1)
    assert Cache.get(:key) == {:ok, :value}
  end

  test "deletes by tuple prefix" do
    Cache.put({:availability_day, ~D[2026-05-07]}, :value, 60)
    Cache.put(:my_bookings, :bookings, 60)

    Cache.delete_prefix(:availability_day)

    assert Cache.get({:availability_day, ~D[2026-05-07]}) == :miss
    assert Cache.get(:my_bookings) == {:ok, :bookings}
  end
end
