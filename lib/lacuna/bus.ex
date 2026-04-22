defmodule Lacuna.Bus do
  @moduledoc """
  Tiny pubsub on top of `:pg`. Subscribers join the `:lacuna_events`
  group; publishers fan a message out to every member.

  Centralised here so the poller, telegram bot, and any future plugin
  notifier all couple to the same topic without taking a hard
  dependency on each other.
  """

  @group :lacuna_events

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link do
    case :pg.start_link(__MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Subscribe the calling process to all bus events."
  def subscribe, do: :pg.join(__MODULE__, @group, self())

  @doc "Stop receiving bus events."
  def unsubscribe, do: :pg.leave(__MODULE__, @group, self())

  @doc "Fan event out to every subscriber. Always returns :ok."
  def publish(event) do
    Enum.each(:pg.get_members(__MODULE__, @group), fn pid ->
      send(pid, {:lacuna_event, event})
    end)

    :ok
  end
end
