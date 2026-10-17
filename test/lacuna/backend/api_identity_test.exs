defmodule Lacuna.Backend.APIIdentityTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.API

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    on_exit(fn -> Application.put_env(:lacuna, :backend_base_url, old) end)
    %{bypass: bypass}
  end

  test "availability binds omitted identity and rejects a conflicting identity", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/facilities/m_get_facility_bookings_info", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = URI.decode_query(body)["facility_id"]
      details = if id == "court-a", do: %{}, else: %{"facility_id" => "court-c"}
      Plug.Conn.resp(conn, 200, envelope(%{"facility_details" => details}))
    end)

    assert {:ok, %{"facility_id" => "court-a"}} =
             API.facility_availability(nil, "court-a", ~D[2099-01-01])

    assert {:error, :availability_identity_mismatch} =
             API.facility_availability(nil, "court-b", ~D[2099-01-01])
  end

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
