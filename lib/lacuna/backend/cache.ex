defmodule Lacuna.Backend.Cache do
  @moduledoc "Small in-memory cache for Telegram UI reads."

  use GenServer

  @type key :: term()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec get(key()) :: {:ok, term()} | :miss
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @spec put(key(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_seconds),
    do: GenServer.cast(__MODULE__, {:put, key, value, ttl_seconds})

  @spec delete(key()) :: :ok
  def delete(key), do: GenServer.cast(__MODULE__, {:delete, key})

  @spec delete_prefix(term()) :: :ok
  def delete_prefix(prefix), do: GenServer.cast(__MODULE__, {:delete_prefix, prefix})

  @spec clear() :: :ok
  def clear, do: GenServer.cast(__MODULE__, :clear)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, key) do
      {value, expires_at} when expires_at > now ->
        {:reply, {:ok, value}, state}

      {_value, _expired} ->
        {:reply, :miss, Map.delete(state, key)}

      nil ->
        {:reply, :miss, state}
    end
  end

  @impl true
  def handle_cast({:put, _key, _value, ttl_seconds}, state) when ttl_seconds <= 0,
    do: {:noreply, state}

  def handle_cast({:put, key, value, ttl_seconds}, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl_seconds * 1_000
    {:noreply, Map.put(state, key, {value, expires_at})}
  end

  def handle_cast({:delete, key}, state), do: {:noreply, Map.delete(state, key)}

  def handle_cast({:delete_prefix, prefix}, state) do
    {:noreply, Map.reject(state, fn {key, _value} -> prefix?(key, prefix) end)}
  end

  def handle_cast(:clear, _state), do: {:noreply, %{}}

  defp prefix?(key, prefix) when is_tuple(key), do: tuple_size(key) > 0 and elem(key, 0) == prefix
  defp prefix?(key, prefix), do: key == prefix
end
