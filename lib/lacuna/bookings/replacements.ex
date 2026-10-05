defmodule Lacuna.Bookings.Replacements do
  @moduledoc "Short-lived, single-use replacement confirmations bound to a Telegram actor and chat."
  use GenServer

  @ttl_ms 5 * 60 * 1_000
  @max_pending 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def prepare(slot, booking, owner),
    do: GenServer.call(__MODULE__, {:prepare, slot, booking, owner})

  def take(token, owner), do: GenServer.call(__MODULE__, {:take, token, owner})
  def discard(token, owner), do: take(token, owner)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:prepare, slot, booking, owner}, _, state) do
    state = prune(state)

    if map_size(state) >= @max_pending do
      {:reply, {:error, :too_many_pending_replacements}, state}
    else
      token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

      intent = %{
        slot: slot,
        booking_id: booking["booking_id"],
        expected_booking: Lacuna.Bookings.snapshot(booking),
        owner: owner,
        expires_at: now() + @ttl_ms
      }

      {:reply, {:ok, token}, Map.put(state, token, intent)}
    end
  end

  def handle_call({:take, token, owner}, _, state) do
    state = prune(state)

    case Map.get(state, token) do
      %{owner: ^owner} = intent -> {:reply, {:ok, intent}, Map.delete(state, token)}
      nil -> {:reply, {:error, :replacement_expired}, state}
      _ -> {:reply, {:error, :replacement_wrong_actor}, state}
    end
  end

  defp prune(state), do: Map.reject(state, fn {_, intent} -> intent.expires_at <= now() end)
  defp now, do: System.monotonic_time(:millisecond)
end
