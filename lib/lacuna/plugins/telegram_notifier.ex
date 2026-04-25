defmodule Lacuna.Plugins.TelegramNotifier do
  @moduledoc """
  Subscribes to the Lacuna event bus and forwards interesting events to
  the configured Telegram group.

  The forwarding logic itself lives in `Lacuna.Telegram.Views` so this
  module stays a thin pump.
  """

  use GenServer
  require Logger

  alias Lacuna.{Bus, Telegram}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Bus.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:lacuna_event, event}, state) do
    try do
      Telegram.Views.handle_event(event)
    rescue
      e -> Logger.error("TelegramNotifier handle_event raised: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
