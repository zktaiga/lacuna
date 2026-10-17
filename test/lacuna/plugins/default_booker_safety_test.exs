defmodule Lacuna.Plugins.DefaultBookerSafetyTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.{Cache, Session}
  alias Lacuna.Plugins.DefaultBooker
  alias Lacuna.Slot

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    Application.put_env(:lacuna, :session_cache_path, nil)
    on_exit(fn -> Application.put_env(:lacuna, :backend_base_url, old) end)
    start_supervised!(Session)
    start_supervised!(Cache)
    Session.configure("operator@example.test", "synthetic-password")
    state = start_supervised!({Agent, fn -> %{writes: 0} end})
    %{bypass: bypass, state: state}
  end

  for {label, changes, expected} <- [
        {"paid", %{"is_chargeable" => "1"}, :paid_facility_unsupported},
        {"unknown-price", %{"is_chargeable" => nil}, :unknown_facility_price},
        {"windowed", %{"is_facility_fixed_slot_based" => false}, :unsupported_booking_mode}
      ] do
    test "direct plugin refuses #{label} metadata before creation", ctx do
      serve(ctx, details: Map.merge(details(), unquote(Macro.escape(changes))))
      assert {:error, unquote(expected)} = DefaultBooker.book(slot(), %{})
      assert Agent.get(ctx.state, & &1.writes) == 0
    end
  end

  test "missing booking unit cannot reach creation", ctx do
    serve(ctx, unit: nil)
    assert {:error, :booking_unit_unavailable} = DefaultBooker.book(slot(), %{})
    assert Agent.get(ctx.state, & &1.writes) == 0
  end

  test "failed inventory read cannot reach creation", ctx do
    serve(ctx, inventory_error: true)
    assert {:error, {:upstream, 503, "Unavailable"}} = DefaultBooker.book(slot(), %{})
    assert Agent.get(ctx.state, & &1.writes) == 0
  end

  test "explicitly free fixed metadata remains bookable without a rate field", ctx do
    serve(ctx)
    assert {:ok, %{booking: %{"booking_id" => "new"}}} = DefaultBooker.book(slot(), %{})
    assert Agent.get(ctx.state, & &1.writes) == 1
  end

  defp serve(ctx, opts \\ []) do
    Bypass.expect(ctx.bypass, fn conn ->
      data =
        case conn.request_path do
          "/auth/m_login/" ->
            %{"comm_id" => "synthetic-community", "user_id" => "synthetic-user"}

          "/community_v2/m_get_dashboard_static_data/" ->
            %{}

          "/runit/m_get_member_ru_and_gst_details/" ->
            case Keyword.get(opts, :unit, "synthetic-unit") do
              nil -> %{}
              unit -> %{"ru_id" => unit}
            end

          "/facilities/m_get_facility_bookings_info" ->
            %{"facility_details" => Keyword.get(opts, :details, details())}

          "/facilities/m_member_make_booking" ->
            Agent.update(ctx.state, &%{&1 | writes: &1.writes + 1})
            %{"booking_id" => "new"}

          "/facilities/m_get_my_bookings_v3" ->
            rows = if Agent.get(ctx.state, & &1.writes) > 0, do: [booking()], else: []

            %{
              "my_bookings" => %{"Upcoming bookings" => rows},
              "offset_details" => %{"upcoming_offset" => -1, "past_offset" => -1}
            }
        end

      response =
        if opts[:inventory_error] && conn.request_path == "/facilities/m_get_my_bookings_v3",
          do: %{"m_app_status_code" => 503, "m_app_status_msg" => "Unavailable"},
          else: %{"m_app_status_code" => 200, "m_response_data" => Jason.encode!(data)}

      conn =
        if conn.request_path == "/auth/m_login/",
          do: Plug.Conn.put_resp_header(conn, "set-cookie", "acsession=synthetic; Path=/"),
          else: conn

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{"m_system_status_code" => 200, "m_app_response" => response})
      )
    end)
  end

  defp details,
    do: %{
      "is_facility_fixed_slot_based" => "1",
      "fixed_time_slots" => %{"slot-a" => "19:00 - 20:00"},
      "is_chargeable" => "0",
      "start_hour" => 18,
      "start_min" => 0,
      "end_hour" => 21,
      "end_min" => 0
    }

  defp slot,
    do: %Slot{
      facility_id: "court-a",
      facility_name: "Synthetic Court",
      date: ~D[2099-05-24],
      start_time: ~T[19:00:00],
      end_time: ~T[20:00:00],
      slot_id: "slot-a",
      fee_aed: 0
    }

  defp booking,
    do: %{
      "booking_id" => "new",
      "facility_id" => "court-a",
      "facility_name" => "Synthetic Court",
      "start_date" => "24-May-2099",
      "start_time" => "19:00",
      "end_time" => "20:00",
      "type" => "upcoming_bookings",
      "status" => "Booked"
    }
end
