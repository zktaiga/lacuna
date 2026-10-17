defmodule Lacuna.Backend.APIExpiryTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.{API, Session}

  setup do
    bypass = Bypass.open()

    old =
      Map.new([:backend_base_url, :session_cache_path], &{&1, Application.get_env(:lacuna, &1)})

    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.delete_env(:lacuna, :session_cache_path)

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:lacuna, key),
          else: Application.put_env(:lacuna, key, value)
      end)
    end)

    %{bypass: bypass}
  end

  for {label, expires} <- [
        {"RFC7231 space", "Wed, 21 Oct 2037 07:28:00 GMT"},
        {"legacy hyphen", "Wed, 21-Oct-2037 07:28:00 GMT"},
        {"case-insensitive attribute", "Wed, 21 Oct 2037 07:28:00 GMT"}
      ] do
    test "parses #{label} expiry", %{bypass: bypass} do
      attr = if unquote(label) == "case-insensitive attribute", do: "eXpIrEs", else: "Expires"
      login_flow(bypass, "acsession=first; " <> attr <> "=" <> unquote(expires))
      assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
      assert login.acsession_expires_at == ~U[2037-10-21 07:28:00Z]
    end
  end

  test "Max-Age takes precedence over Expires, including zero", %{bypass: bypass} do
    login_flow(bypass, "acsession=first; mAx-AgE=0; Expires=Wed, 21-Oct-2037 07:28:00 GMT")
    before = DateTime.utc_now()
    assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
    assert DateTime.diff(login.acsession_expires_at, before, :second) in 0..1
  end

  test "dashboard rotation can shorten the login expiry", %{bypass: bypass} do
    login_flow(
      bypass,
      "acsession=first; Expires=Wed, 21-Oct-2037 07:28:00 GMT",
      "acsession=second; Expires=Tue, 20-Oct-2037 07:28:00 GMT"
    )

    assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
    assert login.acsession_expires_at == ~U[2037-10-20 07:28:00Z]
  end

  test "unit response rotation can shorten dashboard expiry", %{bypass: bypass} do
    login_flow(
      bypass,
      "acsession=first; Expires=Wed, 21-Oct-2037 07:28:00 GMT",
      "acsession=second; Expires=Tue, 20-Oct-2037 07:28:00 GMT",
      "acsession=third; Expires=Mon, 19-Oct-2037 07:28:00 GMT"
    )

    assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
    assert login.acsession_expires_at == ~U[2037-10-19 07:28:00Z]
  end

  test "the last acsession cookie determines both value and expiry", %{bypass: bypass} do
    login_flow(bypass, [
      "acsession=first; Expires=Wed, 21-Oct-2037 07:28:00 GMT",
      "acsession=last; Expires=Tue, 20-Oct-2037 07:28:00 GMT"
    ])

    assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
    assert login.cookie == "acsession=last"
    assert login.acsession_expires_at == ~U[2037-10-20 07:28:00Z]
  end

  test "rotation without an expiry clears the previous cookie's expiry", %{bypass: bypass} do
    login_flow(
      bypass,
      "acsession=first; Expires=Wed, 21-Oct-2037 07:28:00 GMT",
      "acsession=second; Path=/"
    )

    assert {:ok, login} = API.login("operator@example.test", "synthetic-password")
    assert login.acsession_expires_at == nil
  end

  test "authenticated response shortens the current lease expiry and auxiliary cookies preserve it",
       %{bypass: bypass} do
    login_flow(bypass, "acsession=first; Expires=Wed, 21-Oct-2037 07:28:00 GMT")
    start_supervised!(Session)
    Session.configure("operator@example.test", "synthetic-password")
    session = Session.current!()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      conn
      |> cookies("acsession=second; Expires=Tue, 20 Oct 2037 07:28:00 GMT")
      |> reply(%{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    assert {:ok, _} = API.my_bookings(session)
    assert Session.lease_info().acsession_expires_at == ~U[2037-10-20 07:28:00Z]

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      conn
      |> cookies("aux=present; Max-Age=1")
      |> reply(%{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    assert {:ok, _} = API.my_bookings(session)
    assert Session.lease_info().acsession_expires_at == ~U[2037-10-20 07:28:00Z]
  end

  test "malformed Expires is tolerated as unknown rather than raising", %{bypass: bypass} do
    login_flow(bypass, "acsession=first; Expires=not-a-date")

    assert {:ok, %{acsession_expires_at: nil}} =
             API.login("operator@example.test", "synthetic-password")
  end

  defp login_flow(bypass, login, dashboard \\ nil, unit \\ nil) do
    Bypass.stub(bypass, "POST", "/auth/m_login/", fn conn ->
      conn |> cookies(login) |> reply(%{"comm_id" => "community-test", "user_id" => "user-test"})
    end)

    Bypass.stub(bypass, "POST", "/community_v2/m_get_dashboard_static_data/", fn conn ->
      conn |> cookies(dashboard) |> reply(%{})
    end)

    Bypass.stub(bypass, "POST", "/runit/m_get_member_ru_and_gst_details/", fn conn ->
      conn |> cookies(unit) |> reply(%{"ru_id" => "unit-test"})
    end)
  end

  defp cookies(conn, nil), do: conn
  # Cowboy emits repeated response headers in reverse insertion order.
  defp cookies(conn, lines),
    do:
      Plug.Conn.prepend_resp_headers(
        conn,
        Enum.map(Enum.reverse(List.wrap(lines)), &{"set-cookie", &1})
      )

  defp reply(conn, data) do
    Plug.Conn.resp(
      conn,
      200,
      Jason.encode!(%{
        "m_system_status_code" => 200,
        "m_app_response" => %{
          "m_app_status_code" => 200,
          "m_response_data" => Jason.encode!(data)
        }
      })
    )
  end
end
