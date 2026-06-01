defmodule Lacuna.Telegram.FreeSessions do
  @moduledoc "Short-lived state for `/free` inline-keyboard sessions."

  use GenServer
  require Logger

  @type id :: String.t()

  defstruct [:id, :chat_id, :message_id, :created_at]

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec create(integer(), integer() | nil) :: id()
  def create(chat_id, message_id \\ nil) do
    id = new_id()

    GenServer.cast(
      __MODULE__,
      {:put, %__MODULE__{id: id, chat_id: chat_id, message_id: message_id, created_at: now_ms()}}
    )

    id
  end

  @spec attach_message(id(), integer()) :: :ok
  def attach_message(id, message_id),
    do: GenServer.cast(__MODULE__, {:attach_message, id, message_id})

  @spec valid?(id(), integer(), integer() | nil) :: boolean()
  def valid?(id, chat_id, message_id \\ nil) do
    GenServer.call(__MODULE__, {:valid?, id, chat_id, message_id})
  catch
    :exit, _ -> false
  end

  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: Application.get_env(:lacuna, :free_session_ttl_seconds, 30 * 60)

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:put, session}, state) do
    {:noreply, prune(Map.put(state, session.id, session))}
  end

  def handle_cast({:attach_message, id, message_id}, state) do
    updated =
      update_in(state, [id], fn
        %__MODULE__{} = session -> %{session | message_id: message_id}
        nil -> nil
      end)

    {:noreply, updated}
  end

  @impl true
  def handle_call({:valid?, id, chat_id, message_id}, _from, state) do
    state = prune(state)

    valid? =
      case Map.get(state, id) do
        %__MODULE__{chat_id: ^chat_id, message_id: stored} ->
          is_nil(stored) or is_nil(message_id) or stored == message_id

        _ ->
          false
      end

    Logger.debug("/free callback session=#{id} valid?=#{valid?}")
    {:reply, valid?, state}
  end

  defp prune(state) do
    cutoff = now_ms() - ttl_seconds() * 1_000

    Map.reject(state, fn {_id, %__MODULE__{created_at: created_at}} ->
      created_at <= cutoff
    end)
  end

  defp new_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
