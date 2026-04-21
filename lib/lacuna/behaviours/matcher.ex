defmodule Lacuna.Behaviours.Matcher do
  @moduledoc """
  Plug-in surface for filtering which slots count as "interesting" for the
  user. The default matcher applies the rules in `prefs.toml` (court
  whitelist, weekday/hour windows, max fee). Add another module
  implementing this behaviour to layer in custom logic without touching
  the watcher.
  """

  alias Lacuna.Slot

  @callback matches?(Slot.t(), prefs :: map()) :: boolean()
end
