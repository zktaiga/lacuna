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

  test "make_booking accepts string success codes with empty response data", %{bypass: bypass} do
    Bypass.expect(bypass, &route(&1, booking_response: app_success_string(nil)))

    session = Session.current!()

    assert {:ok, %{}} = API.make_booking(session, %{"facility_id" => "court-a"})
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
    {:ok, reads} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(reads), do: Agent.stop(reads) end)

    Bypass.expect(
      bypass,
      &route(&1,
        snapshot_reads: reads,
        booking_response: envelope(%{"booking_id" => "booking-1"}),
        bookings_response:
          bookings([
            %{
              "type" => "upcoming_bookings",
              "status" => "confirmed",
              "booking_id" => "booking-1",
              "facility_id" => "court-a",
              "facility_name" => "Court A",
              "start_date" => "24/05/2099",
              "start_time" => "19:00",
              "end_time" => "20:00"
            }
          ])
      )
    )

    assert {:ok, %{booking: %{"booking_id" => "booking-1"}}} = DefaultBooker.book(slot, %{})
  end

  test "book confirms by response booking id when booking shape drifts", %{
    bypass: bypass,
    slot: slot
  } do
    {:ok, reads} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(reads), do: Agent.stop(reads) end)

    Bypass.expect(
      bypass,
      &route(&1,
        snapshot_reads: reads,
        booking_response: envelope(%{"booking_id" => 34624}),
        bookings_response:
          bookings([
            %{
              "type" => "upcoming_bookings",
              "status" => "Booked",
              "booking_id" => "34624",
              "facility_id" => "different-court",
              "facility_name" => "Different Court",
              "start_date" => "unexpected-date-format",
              "start_time" => "19:00",
              "end_time" => "20:00"
            }
          ])
      )
    )

    assert {:ok, %{booking: %{"booking_id" => "34624"}}} = DefaultBooker.book(slot, %{})
  end

  test "book matches provider day-month-name booking dates without response id", %{
    bypass: bypass,
    slot: slot
  } do
    {:ok, reads} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(reads), do: Agent.stop(reads) end)

    Bypass.expect(
      bypass,
      &route(&1,
        snapshot_reads: reads,
        booking_response: envelope(%{}),
        bookings_response:
          bookings([
            %{
              "type" => "upcoming_bookings",
              "status" => "Booked",
              "booking_id" => "booking-1",
              "facility_id" => "court-a",
              "facility_name" => "Court A",
              "start_date" => "24-May-2099",
              "start_time" => "19:00",
              "end_time" => "20:00"
            }
          ])
      )
    )

    assert {:ok, %{booking: %{"booking_id" => "booking-1"}}} = DefaultBooker.book(slot, %{})
  end

  test "returned id cannot fall back to an older matching slot", %{bypass: bypass, slot: slot} do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{"booking_id" => "new-id"}),
        bookings_response: bookings([matching_booking("old-id")])
      )
    )

    assert {:error, {:booking_not_confirmed, %{"booking_id" => "new-id"}}} =
             DefaultBooker.book(slot, %{})
  end

  test "returned existing ID cannot confirm a new creation", %{bypass: bypass, slot: slot} do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{"booking_id" => "old-id"}),
        bookings_response: bookings([matching_booking("old-id")])
      )
    )

    assert {:error, {:booking_not_confirmed, _}} = DefaultBooker.book(slot, %{})
  end

  test "no response id cannot confirm an existing matching booking", %{bypass: bypass, slot: slot} do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{}),
        bookings_response: bookings([matching_booking("old-id")])
      )
    )

    assert {:error, {:booking_not_confirmed, %{}}} = DefaultBooker.book(slot, %{})
  end

  test "new records still must be active and match the requested slot", %{
    bypass: bypass,
    slot: slot
  } do
    {:ok, reads} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(reads), do: Agent.stop(reads) end)

    rejected = [
      matching_booking("cancelled") |> Map.put("status", "Cancelled"),
      matching_booking("past") |> Map.put("type", "past_bookings"),
      matching_booking("wrong-court") |> Map.put("facility_id", "court-b"),
      matching_booking("wrong-time") |> Map.put("end_time", "21:00"),
      matching_booking("wrong-slot") |> Map.put("facility_time_slot_id", "slot-other")
    ]

    Bypass.expect(
      bypass,
      &route(&1,
        snapshot_reads: reads,
        booking_response: envelope(%{}),
        bookings_response: bookings(rejected)
      )
    )

    assert {:error, {:booking_not_confirmed, %{}}} = DefaultBooker.book(slot, %{})
  end

  test "returned id does not confirm a cancelled or past booking", %{bypass: bypass, slot: slot} do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{"booking_id" => "booking-1"}),
        bookings_response:
          bookings([matching_booking("booking-1") |> Map.put("start_date", "24-May-2000")])
      )
    )

    assert {:error, {:booking_not_confirmed, %{"booking_id" => "booking-1"}}} =
             DefaultBooker.book(slot, %{})
  end

  test "failed booking reads return the stable confirmation error", %{bypass: bypass, slot: slot} do
    Bypass.expect(
      bypass,
      &route(&1,
        booking_response: envelope(%{}),
        bookings_response: app_error(503, "Unavailable")
      )
    )

    assert {:error, {:booking_not_confirmed, %{}}} = DefaultBooker.book(slot, %{})
  end

  test "plugin cancellation returns success only after verification", %{bypass: bypass} do
    cancelled = matching_booking("booking-1") |> Map.put("status", "Cancelled")

    Bypass.expect(
      bypass,
      &route(&1,
        cancellation_response: envelope(%{"cancelled" => true}),
        bookings_response: bookings([cancelled])
      )
    )

    assert :ok = DefaultBooker.cancel("booking-1", %{})
  end

  test "plugin cancellation preserves uncertain outcome errors", %{bypass: bypass} do
    Bypass.expect(
      bypass,
      &route(&1,
        cancellation_response: envelope(%{}),
        bookings_response: bookings([matching_booking("booking-1")])
      )
    )

    assert {:error, {:cancellation_not_confirmed, "booking-1", %{}}} =
             DefaultBooker.cancel("booking-1", %{})
  end

  defp matching_booking(id) do
    %{
      "booking_id" => id,
      "type" => "upcoming_bookings",
      "status" => "Booked",
      "facility_id" => "court-a",
      "facility_name" => "Court A",
      "start_date" => "24-May-2099",
      "start_time" => "19:00",
      "end_time" => "20:00"
    }
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

      {"POST", "/facilities/m_cancel_booking/"} ->
        Plug.Conn.resp(conn, 200, Jason.encode!(Keyword.fetch!(opts, :cancellation_response)))

      {"POST", "/facilities/m_member_make_booking"} ->
        Plug.Conn.resp(conn, 200, Jason.encode!(Keyword.fetch!(opts, :booking_response)))

      {"POST", "/facilities/m_get_my_bookings_v3"} ->
        response = Keyword.get(opts, :bookings_response, bookings([]))

        response =
          if reads = opts[:snapshot_reads] do
            if Agent.get_and_update(reads, &{&1, &1 + 1}) == 0, do: bookings([]), else: response
          else
            response
          end

        Plug.Conn.resp(conn, 200, Jason.encode!(response))
    end
  end

  defp slot do
    %Slot{
      facility_id: "court-a",
      facility_name: "Court A",
      date: ~D[2099-05-24],
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

  defp app_success_string(data) do
    %{
      "m_system_status_code" => 200,
      "m_app_response" => %{
        "m_app_status_code" => "200",
        "m_app_status_msg" => nil,
        "m_response_data" => data
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:lacuna, key)
  defp restore_env(key, value), do: Application.put_env(:lacuna, key, value)
end
