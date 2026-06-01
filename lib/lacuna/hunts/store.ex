defmodule Lacuna.Hunts.Store do
  @moduledoc "Persistent store and mutation API for standing hunts."

  use GenServer
  require Logger

  alias Lacuna.Config
  alias Lacuna.Hunts.Hunt

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def list, do: GenServer.call(__MODULE__, :list)
  def active, do: GenServer.call(__MODULE__, :active)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def active?, do: active() != []

  def create_default do
    GenServer.call(__MODULE__, :create_default)
  end

  def toggle_active(id), do: update(id, fn h -> %{h | active?: not h.active?} end)
  def toggle_day(id, day), do: update(id, fn h -> %{h | weekdays: toggle(h.weekdays, day)} end)

  def toggle_time(id, time),
    do: update(id, fn h -> %{h | times: toggle_time_value(h.times, time)} end)

  def set_mode(id, mode), do: update(id, fn h -> %{h | mode: mode, blocked_reason: nil} end)

  def set_after_match(id, after_match),
    do: update(id, fn h -> %{h | after_match: after_match} end)

  def rename(id, name), do: update(id, fn h -> %{h | name: name} end)
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
  def deactivate(id), do: update(id, fn h -> %{h | active?: false} end)
  def block(id, reason), do: update(id, fn h -> %{h | blocked_reason: to_string(reason)} end)
  def clear_block(id), do: update(id, fn h -> %{h | blocked_reason: nil} end)
  def clear_active_booking_blocks, do: GenServer.call(__MODULE__, :clear_active_booking_blocks)

  def matches(slot) do
    active()
    |> Enum.filter(&Hunt.matches?(&1, slot))
  end

  def selected_weekdays do
    active()
    |> Enum.flat_map(& &1.weekdays)
    |> Enum.uniq()
  end

  def time_options do
    Config.load!().hunt.time_options
    |> Enum.map(&parse_time!/1)
  end

  def update(id, fun) when is_function(fun, 1), do: GenServer.call(__MODULE__, {:update, id, fun})

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, load()}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, Map.values(state), state}

  def handle_call(:active, _from, state) do
    {:reply, state |> Map.values() |> Enum.filter(&Hunt.active?/1), state}
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state, id), state}

  def handle_call(:create_default, _from, state) do
    prefs = Config.load!()
    active_count = state |> Map.values() |> Enum.count(&Hunt.active?/1)

    if active_count >= prefs.hunt.max_active_hunts do
      {:reply, {:error, :max_active_hunts}, state}
    else
      hunt =
        Hunt.new(%{
          weekdays: [],
          times: Enum.map(prefs.hunt.default_times, &parse_time!/1),
          after_match: String.to_atom(prefs.hunt.default_after_match)
        })

      new_state = Map.put(state, hunt.id, hunt)
      persist(new_state)
      wake_poller()
      {:reply, {:ok, hunt}, new_state}
    end
  end

  def handle_call({:update, id, fun}, _from, state) do
    case Map.get(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      hunt ->
        updated = hunt |> fun.() |> Hunt.touch()
        new_state = Map.put(state, id, updated)
        persist(new_state)
        wake_poller()
        {:reply, {:ok, updated}, new_state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    new_state = Map.delete(state, id)
    persist(new_state)
    wake_poller()
    {:reply, :ok, new_state}
  end

  def handle_call(:clear_active_booking_blocks, _from, state) do
    new_state =
      Map.new(state, fn {id, hunt} ->
        if hunt.blocked_reason == "active_booking_limit" do
          {id, Hunt.touch(%{hunt | blocked_reason: nil})}
        else
          {id, hunt}
        end
      end)

    persist(new_state)
    wake_poller()
    {:reply, :ok, new_state}
  end

  defp load do
    with path when is_binary(path) and path != "" <- path(),
         {:ok, raw} <- File.read(path),
         {:ok, list} when is_list(list) <- Jason.decode(raw) do
      Map.new(list, fn item ->
        hunt = Hunt.from_json(item)
        {hunt.id, hunt}
      end)
    else
      _ -> %{}
    end
  end

  defp persist(state) do
    with path when is_binary(path) and path != "" <- path(),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".tmp"
      data = state |> Map.values() |> Enum.map(&Hunt.to_json/1) |> Jason.encode!()
      File.write!(tmp, data)
      File.rename!(tmp, path)
    end
  rescue
    e -> Logger.warning("Failed to persist hunts: #{Exception.message(e)}")
  end

  defp path, do: Application.get_env(:lacuna, :hunt_store_path)

  defp toggle(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  defp toggle_time_value(list, %Time{} = value) do
    value = Time.truncate(value, :second)

    if Enum.any?(list, &(Time.compare(&1, value) == :eq)) do
      Enum.reject(list, &(Time.compare(&1, value) == :eq))
    else
      list ++ [value]
    end
  end

  defp parse_time!(value) when is_binary(value) do
    value = if String.length(value) == 5, do: value <> ":00", else: value
    {:ok, time} = Time.from_iso8601(value)
    Time.truncate(time, :second)
  end

  defp wake_poller do
    case Process.whereis(Lacuna.Watcher.Poller) do
      pid when is_pid(pid) -> send(pid, :hunts_changed)
      _ -> :ok
    end
  end
end
