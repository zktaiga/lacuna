defmodule Lacuna.Backend.APIInventoryTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.API

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    on_exit(fn -> Application.put_env(:lacuna, :backend_base_url, old) end)
    %{bypass: bypass}
  end

  test "public booking API fetches every upcoming page with the returned cursor", %{
    bypass: bypass
  } do
    Bypass.expect(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      offsets = body |> URI.decode_query() |> Map.fetch!("offset_details") |> Jason.decode!()

      data =
        case offsets do
          %{"upcoming_offset" => 0, "past_offset" => 0} -> page("a", 5, 15)
          %{"upcoming_offset" => 5, "past_offset" => 15} -> page("b", -1, 30)
        end

      Plug.Conn.resp(conn, 200, envelope(data))
    end)

    assert {:ok, data} = API.my_bookings(nil)
    assert Enum.map(data["my_bookings"]["Upcoming bookings"], & &1["booking_id"]) == ["a", "b"]
  end

  test "missing pagination metadata does not become a complete empty inventory", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      Plug.Conn.resp(conn, 200, envelope(%{"my_bookings" => %{}}))
    end)

    assert {:error, :incomplete_bookings} = API.my_bookings(nil)
  end

  defp page(id, upcoming, past),
    do: %{
      "my_bookings" => %{
        "Upcoming bookings" => [%{"booking_id" => id, "type" => "upcoming_bookings"}]
      },
      "offset_details" => %{"upcoming_offset" => upcoming, "past_offset" => past}
    }

  defp envelope(data),
    do:
      Jason.encode!(%{
        "m_system_status_code" => 200,
        "m_app_response" => %{
          "m_app_status_code" => 200,
          "m_response_data" => Jason.encode!(data)
        }
      })
end
