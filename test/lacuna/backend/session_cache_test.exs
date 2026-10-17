defmodule Lacuna.Backend.SessionCacheTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.{API, Contract, Session}

  setup %{tmp_dir: tmp_dir} do
    bypass = Bypass.open()

    old =
      Map.new([:backend_base_url, :session_cache_path], &{&1, Application.get_env(:lacuna, &1)})

    path = Path.join(tmp_dir, "session.json")
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.put_env(:lacuna, :session_cache_path, path)

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:lacuna, key),
          else: Application.put_env(:lacuna, key, value)
      end)
    end)

    start_supervised!(Session)

    Bypass.stub(bypass, "POST", "/auth/m_login/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=synthetic-lease; Path=/")
      |> reply(%{"comm_id" => "community-test", "user_id" => "user-test"})
    end)

    Bypass.stub(bypass, "POST", "/community_v2/m_get_dashboard_static_data/", &reply(&1, %{}))

    Bypass.stub(
      bypass,
      "POST",
      "/runit/m_get_member_ru_and_gst_details/",
      &reply(&1, %{"ru_id" => "unit-test"})
    )

    %{bypass: bypass, path: path}
  end

  @tag :tmp_dir
  test "same configure preserves a valid in-memory lease even without a cache", %{path: path} do
    Session.configure("one@example.test", "synthetic-one")
    session = Session.current!()
    File.rm!(path)
    assert :ok = Session.configure("one@example.test", "synthetic-one")
    assert Session.lease_info().status == :ok
    assert Session.current!() == session
  end

  @tag :tmp_dir
  test "same configure does not replace a newer in-memory lease with disk state", %{
    bypass: bypass,
    path: path
  } do
    Session.configure("one@example.test", "synthetic-one")
    session = Session.current!()
    saved = File.read!(path)

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=rotated; Path=/")
      |> reply(%{"my_bookings" => %{}})
    end)

    assert {:ok, _} = API.my_bookings(session)
    assert Session.current!().cookie == "acsession=rotated"
    File.write!(path, saved)
    Session.configure("one@example.test", "synthetic-one")
    assert Session.current!().cookie == "acsession=rotated"
  end

  @tag :tmp_dir
  test "a persisted cache restores for the exact configured credentials", %{path: path} do
    Session.configure("one@example.test", "synthetic-one")
    original = Session.current!()
    data = Jason.decode!(File.read!(path))
    assert is_binary(data["operator_fingerprint"])
    refute File.read!(path) =~ "one@example.test"
    refute File.read!(path) =~ "synthetic-one"
    stop_supervised!(Session)
    start_supervised!(Session)
    Session.configure("one@example.test", "synthetic-one")
    assert Session.lease_info().status == :ok
    assert Session.current!().cookie == original.cookie
  end

  for {description, email, password} <- [
        {"operator", "two@example.test", "synthetic-one"},
        {"password", "one@example.test", "synthetic-two"}
      ] do
    @tag :tmp_dir
    test "changing #{description} rejects another credential context's persisted cache", %{
      path: path
    } do
      Session.configure("one@example.test", "synthetic-one")
      _ = Session.current!()
      assert File.exists?(path)
      stop_supervised!(Session)
      start_supervised!(Session)
      Session.configure(unquote(email), unquote(password))
      assert Session.lease_info().status == :idle
    end

    @tag :tmp_dir
    test "changing #{description} clears identity fields, disk cache, and auth backoff", %{
      path: path
    } do
      Session.configure("one@example.test", "synthetic-one")
      _ = Session.current!()
      Session.record_auth_failure()
      Session.record_auth_failure()
      assert {:pause, _} = Session.record_auth_failure()
      Session.configure(unquote(email), unquote(password))
      state = :sys.get_state(Session)
      assert state.status == :idle
      assert state.cookie == nil
      assert state.session_id == nil
      assert state.user_id == nil
      assert state.comm_id == nil
      assert state.ru_id == nil
      assert state.uris == []
      assert state.logged_in_at == nil
      assert state.last_success_at == nil
      assert state.acsession_expires_at == nil
      assert state.auth_failures == []
      assert state.auth_paused_until == nil
      refute File.exists?(path)
    end
  end

  @tag :tmp_dir
  test "an unstamped legacy cache is never adopted", %{path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "backend_base_url" => Contract.base_url(),
        "backend_client_package" => Contract.client_package(),
        "backend_client_build" => Contract.client_build(),
        "logged_in_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "cookie" => "acsession=legacy",
        "user_id" => "legacy-user",
        "ru_id" => "legacy-unit"
      })
    )

    Session.configure("one@example.test", "synthetic-one")
    assert Session.lease_info().status == :idle
  end

  @tag :tmp_dir
  test "an old-account in-flight response cannot restore auth after reconfigure", %{
    bypass: bypass,
    path: path
  } do
    Session.configure("one@example.test", "synthetic-one")
    session = Session.current!()
    parent = self()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      send(parent, {:pending, self()})

      receive do
        :release -> :ok
      after
        2000 -> flunk("response not released")
      end

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=old-account-rotation; Path=/")
      |> reply(%{"my_bookings" => %{}})
    end)

    task = Task.async(fn -> API.my_bookings(session) end)
    assert_receive {:pending, handler}
    Session.configure("two@example.test", "synthetic-two")
    send(handler, :release)
    assert {:ok, _} = Task.await(task)
    assert Session.lease_info().status == :idle
    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "an old-account workflow cannot dispatch with new-account credentials", %{bypass: bypass} do
    Session.configure("one@example.test", "synthetic-one")
    old = Session.current!()
    Session.configure("two@example.test", "synthetic-two")

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn _ ->
      flunk("cross-account request sent")
    end)

    assert {:error, :session_context_changed} = API.my_bookings(old)
    assert Session.lease_info().status == :idle
  end

  @tag :tmp_dir
  test "a late old-account 401 cannot log into the newly configured account", %{bypass: bypass} do
    Session.configure("one@example.test", "synthetic-one")
    old = Session.current!()
    parent = self()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      send(parent, {:pending, self()})

      receive do
        :release -> :ok
      after
        2000 -> flunk("response not released")
      end

      Plug.Conn.resp(conn, 401, "Authentication Required")
    end)

    task = Task.async(fn -> API.my_bookings(old) end)
    assert_receive {:pending, handler}
    Session.configure("two@example.test", "synthetic-two")
    send(handler, :release)
    assert {:error, :session_context_changed} = Task.await(task)
    assert Session.lease_info().status == :idle
  end

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
