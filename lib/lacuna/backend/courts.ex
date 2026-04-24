defmodule Lacuna.Backend.Courts do
  @moduledoc """
  Catalog of the amenity facility ids the bot watches.

  Persisted in `courts.json` so first-run discovery can write it once and
  subsequent runs just read it. Until that file exists we expose
  `:not_yet_discovered` so the bot can hint the user.

  Which facilities count as "ours" is determined by the `[match].category`
  string in `prefs.toml`: case-insensitive substring match against either
  `category_name` or `facility_name` returned by the upstream.
  """

  require Logger

  @type court :: %{
          id: String.t(),
          name: String.t(),
          short_name: String.t()
        }

  @spec load() :: {:ok, [court()]} | {:error, :not_yet_discovered}
  def load do
    path = Application.fetch_env!(:lacuna, :courts_path)

    case File.read(path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, %{"courts" => list}} when is_list(list) ->
            {:ok, Enum.map(list, &normalize/1)}

          _ ->
            {:error, :not_yet_discovered}
        end

      {:error, :enoent} ->
        {:error, :not_yet_discovered}
    end
  end

  @spec save([court()]) :: :ok | {:error, term()}
  def save(courts) do
    path = Application.fetch_env!(:lacuna, :courts_path)
    File.write(path, Jason.encode!(%{courts: courts}, pretty: true))
  end

  @doc """
  Filter a live facility list down to ones whose `category_name` or
  `facility_name` matches the given category substring (case-insensitive).
  Returns the original list when `category` is empty.
  """
  @spec filter_by_category([map()], String.t()) :: [map()]
  def filter_by_category(facilities, category) when is_binary(category) do
    needle = String.downcase(String.trim(category))

    if needle == "" do
      facilities
    else
      Enum.filter(facilities, fn f ->
        name = String.downcase(to_string(Map.get(f, "facility_name", "")))
        cat = String.downcase(to_string(Map.get(f, "category_name", "")))
        String.contains?(name, needle) or String.contains?(cat, needle)
      end)
    end
  end

  defp normalize(%{} = c) do
    %{
      id: Map.get(c, "id"),
      name: Map.get(c, "name"),
      short_name: Map.get(c, "short_name", Map.get(c, "name"))
    }
  end
end
