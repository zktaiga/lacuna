defmodule Lacuna.Backend.APITest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.API

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")

    on_exit(fn ->
      if old,
        do: Application.put_env(:lacuna, :backend_base_url, old),
        else: Application.delete_env(:lacuna, :backend_base_url)
    end)

    %{bypass: bypass}
  end

  test "HTTP 200 cancellation app failures are errors", %{bypass: bypass} do
    serve(bypass, [bookings([active()])], app_error())
    assert {:error, {:upstream, 409, "Cannot cancel"}} = API.cancel_booking(nil, "booking-1")
  end

  test "acknowledged cancellation still active is not success", %{bypass: bypass} do
    serve(bypass, [bookings([active()])], envelope(%{}))

    assert {:error, {:cancellation_not_confirmed, "booking-1", %{}}} =
             API.cancel_booking(nil, "booking-1")
  end

  test "known active booking disappearing after a stale read confirms cancellation", %{
    bypass: bypass
  } do
    serve(
      bypass,
      [bookings([active()]), bookings([active()]), bookings([])],
      envelope(%{"cancelled" => true})
    )

    assert {:ok, %{"cancelled" => true}} = API.cancel_booking(nil, "booking-1")
  end

  test "missing booking before and after cannot confirm a ghost cancellation", %{bypass: bypass} do
    serve(bypass, [bookings([])], envelope(%{}))

    assert {:error, {:cancellation_not_confirmed, "booking-1", %{}}} =
             API.cancel_booking(nil, "booking-1")
  end

  test "explicit cancelled record confirms requested id only", %{bypass: bypass} do
    cancelled = Map.put(active(), "status", " Cancelled ")
    serve(bypass, [bookings([]), bookings([cancelled])], envelope(%{}))
    assert {:ok, %{}} = API.cancel_booking(nil, "booking-1")
  end

  test "malformed or failed reads cannot establish disappearance", %{bypass: bypass} do
    for result <- [envelope(%{}), app_error()] do
      serve(bypass, [bookings([active()]), result], envelope(%{}))

      assert {:error, {:cancellation_not_confirmed, "booking-1", %{}}} =
               API.cancel_booking(nil, "booking-1")
    end
  end

  defp serve(bypass, reads, cancellation) do
    state = start_supervised!({Agent, fn -> reads end}, id: make_ref())

    Bypass.stub(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      response =
        Agent.get_and_update(state, fn
          [one] -> {one, [one]}
          [one | rest] -> {one, rest}
        end)

      Plug.Conn.resp(conn, 200, Jason.encode!(response))
    end)

    Bypass.stub(bypass, "POST", "/facilities/m_cancel_booking/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["booking_id"] == "booking-1"
      Plug.Conn.resp(conn, 200, Jason.encode!(cancellation))
    end)
  end

  defp active,
    do: %{"booking_id" => "booking-1", "type" => "upcoming_bookings", "status" => "Booked"}

  defp bookings(list), do: envelope(%{"my_bookings" => %{"0" => list}})

  defp envelope(data),
    do: %{
      "m_app_response" => %{"m_app_status_code" => 200, "m_response_data" => Jason.encode!(data)}
    }

  defp app_error,
    do: %{
      "m_app_response" => %{
        "m_app_status_code" => 409,
        "m_app_status_msg" => "Cannot cancel",
        "m_response_data" => nil
      }
    }
end
