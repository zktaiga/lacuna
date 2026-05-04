defmodule Lacuna.Backend.SessionTest do
  use ExUnit.Case, async: false

  alias Lacuna.Backend.{API, Session}

  setup do
    bypass = Bypass.open()
    old_base = Application.get_env(:lacuna, :backend_base_url)
    old_pkg = Application.get_env(:lacuna, :backend_client_package)
    old_build = Application.get_env(:lacuna, :backend_client_build)

    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.put_env(:lacuna, :backend_client_package, "com.example.app")
    Application.put_env(:lacuna, :backend_client_build, "123")

    start_supervised!(Session)
    :ok = Session.configure("user@example.test", "secret")

    on_exit(fn ->
      restore_env(:backend_base_url, old_base)
      restore_env(:backend_client_package, old_pkg)
      restore_env(:backend_client_build, old_build)
    end)

    %{bypass: bypass}
  end

  test "authenticated headers mirror the mobile client context", %{bypass: bypass} do
    expect_login_flow(bypass)

    session = Session.current!()
    headers = Session.auth_headers(session)

    assert {"Cookie", "PHPSESSID=php-1; acsession=ac-2"} in headers
    assert {"Session-Id", "PHPSESSID=php-1; acsession=ac-2"} in headers
    assert {"comm_id", "community-1"} in headers
    assert {"Community-Code", ""} in headers
    assert {"Client-Version", "123"} in headers
    assert {"Client-Package", "com.example.app"} in headers
    assert {"X-ACCLIENT", "member_123"} in headers
  end

  test "app-level 401 invalidates cached session, logs in again, and retries once", %{
    bypass: bypass
  } do
    parent = self()
    counter = :counters.new(1, [])

    Bypass.expect(bypass, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/auth/m_login/"} ->
          send(parent, :login)

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
          send(parent, :dashboard)
          Plug.Conn.resp(conn, 200, Jason.encode!(envelope(%{})))

        {"POST", "/runit/m_get_member_ru_and_gst_details/"} ->
          send(parent, :ru)
          Plug.Conn.resp(conn, 200, Jason.encode!(envelope(%{"ru_id" => "unit-1"})))

        {"POST", "/facilities/m_get_my_bookings_v3"} ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)
          send(parent, {:my_bookings, n, Plug.Conn.get_req_header(conn, "comm_id")})

          if n == 1 do
            Plug.Conn.resp(conn, 200, Jason.encode!(app_error(401, "Authentication Required")))
          else
            Plug.Conn.resp(conn, 200, Jason.encode!(envelope(%{"my_bookings" => %{}})))
          end
      end
    end)

    session = Session.current!()
    assert {:ok, %{"my_bookings" => %{}}} = API.my_bookings(session)

    assert_receive :login
    assert_receive :dashboard
    assert_receive :ru
    assert_receive {:my_bookings, 1, ["community-1"]}
    assert_receive :login
    assert_receive :dashboard
    assert_receive :ru
    assert_receive {:my_bookings, 2, ["community-1"]}
  end

  defp expect_login_flow(bypass) do
    Bypass.expect(bypass, fn conn ->
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
      end
    end)
  end

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
