defmodule Lacuna.Plugins.DefaultBookerTest do
  use ExUnit.Case, async: false

  alias Lacuna.Backend.{API, Cache, Session}
  alias Lacuna.Plugins.DefaultBooker
  alias Lacuna.Slot

  setup do
    bypass = Bypass.open()
    old_base = Application.get_env(:lacuna, :backend_base_url)
    old_pkg = Application.get_env(:lacuna, :backend_client_package)
    old_build = Application.get_env(:lacuna, :backend_client_build)

    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.put_env(:lacuna, :backend_client_package, "com.example.app")
    Application.put_env(:lacuna, :backend_client_build, "123")

    start_supervised!(Session)
    start_supervised!(Cache)
    :ok = Session.configure("user@example.test", "secret")

    on_exit(fn ->
      restore_env(:backend_base_url, old_base)
      restore_env(:backend_client_package, old_pkg)
      restore_env(:backend_client_build, old_build)
    end)

    %{bypass: bypass, slot: slot()}
  end

  test "make_booking exposes app-level booking failures", %{bypass: bypass} do
    Bypass.expect(bypass, &route(&1, booking_response: app_error(409, "Already booked")))

    session = Session.current!()

    assert {:error, {:upstream, 409, "Already booked"}} =
             API.make_booking(session, %{"facility_id" => "court-a"})
  end

  test "book fails when the provider accepts the request but no matching booking appears", %{
    bypass: bypass,
    slot: slot
  } do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{}),
        bookings_response: bookings([])
      )
    )

    assert {:error, {:booking_not_confirmed, %{}}} = DefaultBooker.book(slot, %{})
  end

  test "book succeeds only after a matching booking is visible in my bookings", %{
    bypass: bypass,
    slot: slot
  } do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{"booking_id" => "booking-1"}),
        bookings_response:
          bookings([
            %{
              "type" => "upcoming_bookings",
              "status" => "confirmed",
              "booking_id" => "booking-1",
              "facility_id" => "court-a",
              "facility_name" => "Court A",
              "start_date" => "24/05/2026",
              "start_time" => "19:00",
              "end_time" => "20:00"
            }
          ])
      )
    )

    assert {:ok, %{booking: %{"booking_id" => "booking-1"}}} = DefaultBooker.book(slot, %{})
  end

  defp route(conn, opts) do
    case {conn.method, conn.request_path} do
      {"POST", "/auth/m_login/"} ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"set-cookie", "PHPSESSID=php-1; Path=/"},
          {"set-cookie", "acsession=ac-1; Path=/"}
        ])
        |> Plug.Conn.resp(
          200,
          Jason.encode!(envelope(%{"comm_id" => "community-1", "user_id" => "user-1"}))
        )

      {"POST", "/community_v2/m_get_dashboard_static_data/"} ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "acsession=ac-2; Path=/")
        |> Plug.Conn.resp(200, Jason.encode!(envelope(%{})))

      {"POST", "/runit/m_get_member_ru_and_gst_details/"} ->
        Plug.Conn.resp(conn, 200, Jason.encode!(envelope(%{"ru_id" => "unit-1"})))

      {"POST", "/facilities/m_member_make_booking"} ->
        Plug.Conn.resp(conn, 200, Jason.encode!(Keyword.fetch!(opts, :booking_response)))

      {"POST", "/facilities/m_get_my_bookings_v3"} ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(Keyword.get(opts, :bookings_response, bookings([])))
        )
    end
  end

  defp slot do
    %Slot{
      facility_id: "court-a",
      facility_name: "Court A",
      date: ~D[2026-05-24],
      start_time: ~T[19:00:00],
      end_time: ~T[20:00:00],
      slot_id: "slot-1",
      fee_aed: 0
    }
  end

  defp bookings(list), do: envelope(%{"my_bookings" => %{"0" => list}})

  defp envelope(data) do
    %{
      "m_system_status_code" => 200,
      "m_app_response" => %{
        "m_app_status_code" => 200,
        "m_app_status_msg" => "OK",
        "m_response_data" => Jason.encode!(data)
      }
    }
  end

  defp app_error(code, message) do
    %{
      "m_system_status_code" => 200,
      "m_app_response" => %{
        "m_app_status_code" => code,
        "m_app_status_msg" => message,
        "m_response_data" => nil
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:lacuna, key)
  defp restore_env(key, value), do: Application.put_env(:lacuna, key, value)
end
