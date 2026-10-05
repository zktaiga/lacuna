defmodule Lacuna.Backend.SessionLease do
  @moduledoc """
  Expiry-aware background touch for the provider's sliding `acsession` lease.

  This does not login on a fixed timer. It waits until the persisted lease is
  close to expiry, then performs one cheap authenticated read so the provider
  can extend the cookie before the next human action. If the provider has
  already invalidated the lease, normal API auth recovery performs a serialized
  relogin.
  """

  use GenServer
  require Logger

  alias Lacuna.Backend.{API, Session}

  @default_margin_seconds 10 * 60
  @default_unknown_interval_seconds 55 * 60
  @min_delay_ms 60_000
  @max_delay_ms 55 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run one lease touch now. Useful for diagnostics/tests."
  def touch, do: GenServer.call(__MODULE__, :touch, 60_000)

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:touch, _from, state), do: {:reply, touch_once(), state}

  @impl true
  def handle_info(:touch, state) do
    _ = touch_once()
    schedule_next()
    {:noreply, state}
  end

  defp touch_once do
    case Session.lease_info() do
      %{status: :ok} = info ->
        if due?(info) do
          Logger.info("Touching booking backend auth lease before expiry")

          case Session.current!() do
            %Session{} = session ->
              case API.my_bookings(session) do
                {:ok, _} ->
                  Logger.info("Booking backend auth lease touch succeeded")
                  :ok

                {:error, reason} = err ->
                  Logger.warning("Booking backend auth lease touch failed: #{inspect(reason)}")
                  err
              end

            {:error, _} = err ->
              err
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Booking backend auth lease touch raised: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, reason ->
      Logger.warning("Booking backend auth lease touch exited: #{inspect(reason)}")
      {:error, reason}
  end

  defp due?(%{acsession_expires_at: nil}), do: true

  defp due?(%{acsession_expires_at: %DateTime{} = expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) <= margin_seconds()
  end

  defp schedule_next do
    Process.send_after(self(), :touch, next_delay_ms())
  end

  defp next_delay_ms do
    delay =
      case safe_lease_info() do
        %{status: :ok, acsession_expires_at: %DateTime{} = expires_at} ->
          expires_at
          |> DateTime.diff(DateTime.utc_now(), :millisecond)
          |> Kernel.-(margin_seconds() * 1_000)

        %{status: :ok} ->
          unknown_interval_seconds() * 1_000

        _ ->
          @max_delay_ms
      end

    delay
    |> max(@min_delay_ms)
    |> min(@max_delay_ms)
  end

  defp safe_lease_info do
    Session.lease_info()
  catch
    :exit, _ -> %{}
  end

  defp enabled?, do: Application.get_env(:lacuna, :session_lease_touch_enabled, true)

  defp margin_seconds,
    do: Application.get_env(:lacuna, :session_lease_touch_margin_seconds, @default_margin_seconds)

  defp unknown_interval_seconds,
    do:
      Application.get_env(
        :lacuna,
        :session_lease_touch_unknown_interval_seconds,
        @default_unknown_interval_seconds
      )
end
