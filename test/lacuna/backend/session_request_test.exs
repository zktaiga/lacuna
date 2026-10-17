defmodule Lacuna.Backend.SessionRequestTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.{API, Session}

  setup do
    bypass = Bypass.open()
    keys = [:backend_base_url, :session_cache_path, :auth_header_mode]
    old = Map.new(keys, &{&1, Application.get_env(:lacuna, &1)})
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.delete_env(:lacuna, :session_cache_path)
    Application.put_env(:lacuna, :auth_header_mode, :minimal)

    on_exit(fn ->
      Enum.each(old, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:lacuna, key),
          else: Application.put_env(:lacuna, key, value)
      end)
    end)

    start_supervised!(Session)
    Session.configure("operator@example.test", "synthetic-password")
    count = start_supervised!({Agent, fn -> 0 end})

    Bypass.stub(bypass, "POST", "/auth/m_login/", fn conn ->
      n = Agent.get_and_update(count, &{&1 + 1, &1 + 1})

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=lease-#{n}; Path=/")
      |> reply(%{"comm_id" => "community-test", "user_id" => "user-test"})
    end)

    Bypass.stub(bypass, "POST", "/community_v2/m_get_dashboard_static_data/", &reply(&1, %{}))

    Bypass.stub(
      bypass,
      "POST",
      "/runit/m_get_member_ru_and_gst_details/",
      &reply(&1, %{"ru_id" => "unit-test"})
    )

    %{bypass: bypass, count: count}
  end

  for operation <- [:create, :cancel], rejection <- [:http, :application, :system] do
    test "#{operation} mutation is never replayed after #{rejection} authentication rejection",
         ctx do
      assert_never_replayed(ctx, unquote(operation), unquote(rejection))
    end
  end

  defp assert_never_replayed(%{bypass: bypass, count: count}, operation, rejection) do
    session = Session.current!()

    path =
      if operation == :create,
        do: "/facilities/m_member_make_booking",
        else: "/facilities/m_cancel_booking/"

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      reply(conn, %{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    Bypass.expect_once(bypass, "POST", path, fn conn ->
      case rejection do
        :http ->
          Plug.Conn.resp(conn, 401, "Unauthorized")

        :application ->
          Plug.Conn.resp(
            conn,
            200,
            Jason.encode!(%{
              "m_system_status_code" => 200,
              "m_app_response" => %{
                "m_app_status_code" => 401,
                "m_app_status_msg" => "Unauthorized"
              }
            })
          )

        :system ->
          Plug.Conn.resp(conn, 200, Jason.encode!(%{"m_system_status_code" => 401}))
      end
    end)

    result =
      if operation == :create,
        do: API.make_booking(session, %{"facility_id" => "synthetic-court"}),
        else: API.cancel_booking(session, "synthetic-booking")

    assert {:error, _} = result
    assert Agent.get(count, & &1) == 1
  end

  test "a stale workflow sends the current lease without restoring its old jar", %{bypass: bypass} do
    old = Session.current!()
    Session.invalidate()
    fresh = Session.current!()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == [fresh.cookie]

      reply(conn, %{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    assert {:ok, _} = API.my_bookings(old)
    assert Session.current!().cookie == fresh.cookie
  end

  test "a stale workflow merges only response deltas into the lease actually sent", %{
    bypass: bypass
  } do
    old = Session.current!()
    Session.invalidate()
    fresh = Session.current!()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "aux=new; Path=/")
      |> reply(%{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    assert {:ok, _} = API.my_bookings(old)
    assert Session.current!().cookie == fresh.cookie <> "; aux=new"
  end

  test "an in-flight old-lease response cannot overwrite a new login", %{bypass: bypass} do
    old = Session.current!()
    parent = self()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      send(parent, {:pending, self()})

      receive do
        :release -> :ok
      after
        2000 -> flunk("response not released")
      end

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=obsolete; Path=/")
      |> reply(%{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    task = Task.async(fn -> API.my_bookings(old) end)
    assert_receive {:pending, handler}
    Session.invalidate()
    fresh = Session.current!()
    send(handler, :release)
    assert {:ok, _} = Task.await(task)
    assert Session.current!().cookie == fresh.cookie
  end

  test "concurrent same-lease auxiliary deltas are both retained", %{bypass: bypass} do
    session = Session.current!()
    parent = self()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      send(parent, {:pending, self()})

      value =
        receive do
          {:release, value} -> value
        after
          2000 -> flunk("response not released")
        end

      conn
      |> Plug.Conn.put_resp_header("set-cookie", value <> "=present; Path=/")
      |> reply(%{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    a = Task.async(fn -> API.my_bookings(session) end)
    b = Task.async(fn -> API.my_bookings(session) end)
    assert_receive {:pending, first}
    assert_receive {:pending, second}
    send(first, {:release, "first"})
    # Wait for the first request to merge before releasing the second response.
    assert {completed, {:ok, {:ok, _}}} =
             Task.yield_many([a, b], 1000) |> Enum.find(fn {_, result} -> result != nil end)

    send(second, {:release, "second"})
    remaining = if completed == a, do: b, else: a
    assert {:ok, _} = Task.await(remaining)
    current = Session.current!()
    assert current.cookie =~ "first=present"
    assert current.cookie =~ "second=present"
  end

  test "401 classification uses the sent lease rather than the stale workflow", %{
    bypass: bypass,
    count: count
  } do
    old = Session.current!()
    Session.invalidate()
    rejected = Session.current!()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      if Plug.Conn.get_req_header(conn, "cookie") == [rejected.cookie] do
        Plug.Conn.resp(conn, 401, "Authentication Required")
      else
        reply(conn, %{
          "my_bookings" => %{},
          "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
        })
      end
    end)

    assert {:ok, _} = API.my_bookings(old)
    assert Agent.get(count, & &1) == 3
    assert Session.current!().cookie == "acsession=lease-3"
  end

  test "a late 401 retries the newer lease without another login", %{bypass: bypass, count: count} do
    old = Session.current!()
    parent = self()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      if Plug.Conn.get_req_header(conn, "cookie") == [old.cookie] do
        send(parent, {:pending, self()})

        receive do
          :release -> :ok
        after
          2000 -> flunk("response not released")
        end

        Plug.Conn.resp(conn, 401, "Authentication Required")
      else
        reply(conn, %{
          "my_bookings" => %{},
          "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
        })
      end
    end)

    task = Task.async(fn -> API.my_bookings(old) end)
    assert_receive {:pending, handler}
    Session.invalidate()
    fresh = Session.current!()
    send(handler, :release)
    assert {:ok, _} = Task.await(task)
    assert Agent.get(count, & &1) == 2
    assert Session.current!().cookie == fresh.cookie
  end

  test "retry response rotation remains current after the outer request returns", %{
    bypass: bypass
  } do
    session = Session.current!()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      if Plug.Conn.get_req_header(conn, "cookie") == [session.cookie] do
        reply_error(conn, 401)
      else
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "acsession=rotated; Path=/")
        |> reply(%{
          "my_bookings" => %{},
          "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
        })
      end
    end)

    assert {:ok, _} = API.my_bookings(session)
    assert Session.current!().cookie == "acsession=rotated"
  end

  test "request-time auth backoff is returned without using the stale lease", %{bypass: bypass} do
    session = Session.current!()
    Session.record_auth_failure()
    Session.record_auth_failure()
    assert {:pause, _} = Session.record_auth_failure()

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn _ ->
      flunk("paused lease sent")
    end)

    assert {:error, {:auth_backoff, _}} = API.my_bookings(session)
  end

  test "request-time login failure is returned rather than sending an old lease", %{
    bypass: bypass
  } do
    session = Session.current!()
    Session.invalidate()
    Bypass.stub(bypass, "POST", "/auth/m_login/", &Plug.Conn.resp(&1, 503, "Unavailable"))

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn _ ->
      flunk("old lease sent")
    end)

    assert {:error, {:http_status, 503, _}} = API.my_bookings(session)
  end

  test "full mode sends the actual current cookie and matching context", %{bypass: bypass} do
    Application.put_env(:lacuna, :auth_header_mode, :full)
    old = Session.current!()
    Session.invalidate()
    fresh = Session.current!()

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == [fresh.cookie]
      assert Plug.Conn.get_req_header(conn, "session-id") == [fresh.session_id]
      assert Plug.Conn.get_req_header(conn, "comm_id") == [fresh.comm_id]

      reply(conn, %{
        "my_bookings" => %{},
        "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
      })
    end)

    assert {:ok, _} = API.my_bookings(old)
    assert Session.current!().cookie == fresh.cookie
  end

  test "repeated auth rejection retries once and never installs rejected response cookies", %{
    bypass: bypass,
    count: count
  } do
    session = Session.current!()
    requests = start_supervised!({Agent, fn -> 0 end}, id: :requests)

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      Agent.update(requests, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "acsession=rejected; Path=/")
      |> reply_error(401)
    end)

    assert {:error, {:upstream, 401, _}} = API.my_bookings(session)
    assert Agent.get(count, & &1) == 2
    assert Agent.get(requests, & &1) == 2
    assert Session.current!().cookie == "acsession=lease-2"
  end

  test "a response from before cookie rotation cannot undo that rotation", %{bypass: bypass} do
    session = Session.current!()
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end}, id: :calls)

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      if n == 1 do
        send(parent, {:pending, self()})

        receive do
          :release -> :ok
        after
          2000 -> flunk("response not released")
        end

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "acsession=obsolete; Path=/")
        |> reply(%{
          "my_bookings" => %{},
          "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
        })
      else
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "acsession=rotated; Path=/")
        |> reply(%{
          "my_bookings" => %{},
          "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
        })
      end
    end)

    task = Task.async(fn -> API.my_bookings(session) end)
    assert_receive {:pending, handler}
    assert {:ok, _} = API.my_bookings(session)
    send(handler, :release)
    assert {:ok, _} = Task.await(task)
    assert Session.current!().cookie == "acsession=rotated"
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

  defp reply_error(conn, code) do
    Plug.Conn.resp(
      conn,
      200,
      Jason.encode!(%{
        "m_system_status_code" => 200,
        "m_app_response" => %{
          "m_app_status_code" => code,
          "m_app_status_msg" => "Authentication Required",
          "m_response_data" => nil
        }
      })
    )
  end
end
