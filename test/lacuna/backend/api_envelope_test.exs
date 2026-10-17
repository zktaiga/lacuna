defmodule Lacuna.Backend.APIEnvelopeTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.{API, Session}

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")

    on_exit(fn ->
      if old == nil,
        do: Application.delete_env(:lacuna, :backend_base_url),
        else: Application.put_env(:lacuna, :backend_base_url, old)
    end)

    %{bypass: bypass}
  end

  for code <- [500, "503", nil] do
    test "system status #{inspect(code)} is not swallowed by app success", %{bypass: bypass} do
      stub(
        bypass,
        "/facilities/m_get_my_bookings_v3",
        Map.put(envelope(%{"my_bookings" => %{}}), "m_system_status_code", unquote(code))
      )

      assert {:error, {:upstream_system, unquote(code), _}} = API.my_bookings(nil)
    end
  end

  test "a system failure cannot acknowledge booking creation", %{bypass: bypass} do
    stub(
      bypass,
      "/facilities/m_member_make_booking",
      Map.put(envelope(%{"booking_id" => "synthetic-booking"}), "m_system_status_code", 500)
    )

    assert {:error, {:upstream_system, 500, _}} =
             API.make_booking(nil, %{"enc_ru_id" => "unit-test"})
  end

  test "legacy envelopes without a system status remain supported", %{bypass: bypass} do
    stub(
      bypass,
      "/facilities/m_get_my_bookings_v3",
      Map.delete(envelope(%{"my_bookings" => %{}}), "m_system_status_code")
    )

    assert {:ok, %{"my_bookings" => %{}}} = API.my_bookings(nil)
  end

  test "string success statuses remain supported", %{bypass: bypass} do
    body =
      envelope(%{"my_bookings" => %{}})
      |> Map.put("m_system_status_code", "200")
      |> put_in(["m_app_response", "m_app_status_code"], "200")

    stub(bypass, "/facilities/m_get_my_bookings_v3", body)
    assert {:ok, %{"my_bookings" => %{}}} = API.my_bookings(nil)
  end

  test "login system failure stops before dashboard activation", %{bypass: bypass} do
    login(bypass, Map.put(envelope(identity()), "m_system_status_code", 503))

    assert {:error, {:upstream_system, 503, _}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "login app failure is an error", %{bypass: bypass} do
    login(bypass, app_error(403))

    assert {:error, {:upstream, 403, "Rejected"}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "dashboard app failure stops login before unit lookup", %{bypass: bypass} do
    login(bypass, envelope(identity()))
    stub(bypass, "/community_v2/m_get_dashboard_static_data/", app_error(409))

    assert {:error, {:upstream, 409, "Rejected"}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "dashboard system failure stops login before unit lookup", %{bypass: bypass} do
    login(bypass, envelope(identity()))

    stub(
      bypass,
      "/community_v2/m_get_dashboard_static_data/",
      Map.put(envelope(%{}), "m_system_status_code", 500)
    )

    assert {:error, {:upstream_system, 500, _}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "login accepts an already-decoded inner map", %{bypass: bypass} do
    login(bypass, put_in(envelope(identity()), ["m_app_response", "m_response_data"], identity()))
    activated(bypass)

    assert {:ok, %{user_id: "user-test", ru_id: "unit-test"}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "malformed login payload fails without raising", %{bypass: bypass} do
    login(bypass, put_in(envelope(identity()), ["m_app_response", "m_response_data"], nil))

    assert {:error, {:login_unexpected, _}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "login requires a nonempty auth cookie", %{bypass: bypass} do
    login(bypass, envelope(identity()), "aux=present; Path=/")
    activated(bypass)

    assert {:error, :login_missing_auth_cookie} =
             API.login("operator@example.test", "synthetic-password")
  end

  for {field, value} <- [{"user_id", nil}, {"comm_id", ""}] do
    test "login rejects an invalid #{field}", %{bypass: bypass} do
      login(bypass, envelope(Map.put(identity(), unquote(field), unquote(value))))
      activated(bypass)

      assert {:error, {:login_unexpected, _}} =
               API.login("operator@example.test", "synthetic-password")
    end
  end

  test "unit lookup application rejection is not treated as an activated session", %{
    bypass: bypass
  } do
    login(bypass, envelope(identity()))
    stub(bypass, "/community_v2/m_get_dashboard_static_data/", envelope(%{}))
    stub(bypass, "/runit/m_get_member_ru_and_gst_details/", app_error(403))

    assert {:error, {:upstream, 403, "Rejected"}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "unit lookup HTTP rejection is not treated as success", %{bypass: bypass} do
    login(bypass, envelope(identity()))
    stub(bypass, "/community_v2/m_get_dashboard_static_data/", envelope(%{}))

    Bypass.stub(
      bypass,
      "POST",
      "/runit/m_get_member_ru_and_gst_details/",
      &Plug.Conn.resp(&1, 503, "Unavailable")
    )

    assert {:error, {:http_status, 503, _}} =
             API.login("operator@example.test", "synthetic-password")
  end

  test "failed activation never puts the singleton into ok state", %{bypass: bypass} do
    login(bypass, envelope(identity()))
    stub(bypass, "/community_v2/m_get_dashboard_static_data/", app_error(409))
    start_supervised!(Session)
    Session.configure("operator@example.test", "synthetic-password")
    assert {:error, {:upstream, 409, "Rejected"}} = Session.current!()
    assert Session.lease_info().status == :idle
  end

  test "activation cannot return a session after clearing its auth cookie", %{bypass: bypass} do
    login(bypass, envelope(identity()))

    Bypass.stub(bypass, "POST", "/community_v2/m_get_dashboard_static_data/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=; Path=/")
      |> Plug.Conn.resp(200, Jason.encode!(envelope(%{})))
    end)

    stub(bypass, "/runit/m_get_member_ru_and_gst_details/", envelope(%{"ru_id" => "unit-test"}))

    assert {:error, :login_missing_auth_cookie} =
             API.login("operator@example.test", "synthetic-password")
  end

  defp login(bypass, body, cookie \\ "acsession=synthetic-lease; Path=/") do
    Bypass.stub(bypass, "POST", "/auth/m_login/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", cookie)
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp activated(bypass) do
    stub(bypass, "/community_v2/m_get_dashboard_static_data/", envelope(%{}))
    stub(bypass, "/runit/m_get_member_ru_and_gst_details/", envelope(%{"ru_id" => "unit-test"}))
  end

  defp stub(bypass, path, body),
    do: Bypass.stub(bypass, "POST", path, &Plug.Conn.resp(&1, 200, Jason.encode!(body)))

  defp identity, do: %{"comm_id" => "community-test", "user_id" => "user-test"}

  defp envelope(data),
    do: %{
      "m_system_status_code" => 200,
      "m_app_response" => %{
        "m_app_status_code" => 200,
        "m_app_status_msg" => "OK",
        "m_response_data" => Jason.encode!(data)
      }
    }

  defp app_error(code),
    do: %{
      "m_system_status_code" => 200,
      "m_app_response" => %{
        "m_app_status_code" => code,
        "m_app_status_msg" => "Rejected",
        "m_response_data" => nil
      }
    }
end
