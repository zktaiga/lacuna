defmodule Lacuna.Behaviours.Booker do
  @moduledoc """
  Plug-in surface for booking actions. Implementations include the real
  HTTP-API booker and a no-op `DryRun` booker used in tests.
  """

  alias Lacuna.Slot

  @callback book(Slot.t(), context :: map()) ::
              {:ok, booking :: map()} | {:error, term()}

  @callback cancel(booking_id :: String.t(), context :: map()) ::
              :ok | {:error, term()}
end
