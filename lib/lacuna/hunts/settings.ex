defmodule Lacuna.Hunts.Settings do
  @moduledoc "Persistent global hunt settings."

  use GenServer
  require Logger

  defstruct poll_profile: :human_like

  @profiles [:human_like, :fast]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def poll_profile, do: get().poll_profile

  def set_poll_profile(profile) when profile in @profiles do
    GenServer.call(__MODULE__, {:set_poll_profile, profile})
  end

  def profiles, do: @profiles

  @impl true
  def init(_opts), do: {:ok, load()}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:set_poll_profile, profile}, _from, state) do
    state = %{state | poll_profile: profile}
    persist(state)
    wake_poller()
    {:reply, state, state}
  end

  defp load do
    with path when is_binary(path) and path != "" <- path(),
         {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      %__MODULE__{poll_profile: parse_profile(data["poll_profile"])}
    else
      _ -> %__MODULE__{}
    end
  end

  defp persist(state) do
    with path when is_binary(path) and path != "" <- path(),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(%{poll_profile: Atom.to_string(state.poll_profile)}))
      File.rename!(tmp, path)
    end
  rescue
    e -> Logger.warning("Failed to persist hunt settings: #{Exception.message(e)}")
  end

  defp path do
    Application.get_env(:lacuna, :hunt_settings_path) ||
      case Application.get_env(:lacuna, :hunt_store_path) do
        nil -> nil
        store_path -> Path.join(Path.dirname(store_path), "hunt_settings.json")
      end
  end

  defp parse_profile("fast"), do: :fast
  defp parse_profile("human_like"), do: :human_like
  defp parse_profile(_), do: :human_like

  defp wake_poller do
    case Process.whereis(Lacuna.Watcher.Poller) do
      pid when is_pid(pid) -> send(pid, :hunts_changed)
      _ -> :ok
    end
  end
end
