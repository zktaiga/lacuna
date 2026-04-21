defmodule Lacuna.Behaviours.Notifier do
  @moduledoc """
  Plug-in surface for things that want to react to domain events.

  A plugin module declares `@behaviour Lacuna.Behaviours.Notifier`,
  implements `notify/2`, and is listed in `prefs.toml` under `[plugins]
  notifiers = [...]`. The plugin registry instantiates each on boot and
  every event published on the internal `:pg` group is fanned out via
  `notify/2`. Returning `{:error, _}` is logged but never fatal — bad
  notifiers must not take the watcher down.
  """

  alias Lacuna.Slot

  @type event ::
          {:slot_opened, Slot.t()}
          | {:slot_closed, Slot.t()}
          | {:poll_failed, term()}
          | {:booking_succeeded, map()}
          | {:booking_failed, term(), map()}

  @callback notify(event(), context :: map()) :: :ok | {:error, term()}
end
