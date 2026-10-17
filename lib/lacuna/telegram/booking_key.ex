defmodule Lacuna.Telegram.BookingKey do
  @moduledoc "Compact, restart-stable booking callbacks resolved against the configured court catalog."

  alias Lacuna.Backend.Courts
  alias Lacuna.Slot

  def encode(%Slot{} = slot) do
    "v1:#{court_token(slot.facility_id)}|#{Date.to_iso8601(slot.date)}|#{Time.to_iso8601(slot.start_time)}"
  end

  def decode(key, catalog \\ Courts.load()) do
    with [court_key, date_iso, time_iso] <- String.split(key, "|"),
         {:ok, date} <- Date.from_iso8601(date_iso),
         {:ok, time} <- Time.from_iso8601(time_iso),
         {:ok, courts} <- catalog,
         [court] <- Enum.filter(courts, &matches_court?(court_key, &1.id)) do
      {:ok, court.id, date, time}
    else
      _ -> {:error, :invalid_slot_key}
    end
  end

  defp matches_court?("v1:" <> token, id), do: token == court_token(id)
  defp matches_court?(legacy_id, id), do: legacy_id == id

  defp court_token(id) do
    :crypto.hash(:sha256, id)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
