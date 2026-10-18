defmodule Lacuna.Backend.APIInventoryTest do
  use ExUnit.Case, async: false
  alias Lacuna.Backend.API
  alias Lacuna.{Bookings, Clock, Slot}

  defmodule GuardAPI do
    defdelegate my_bookings(session), to: Lacuna.Backend.API

    def facility_availability(_session, _facility_id, _date) do
      send(self(), :unexpected_availability_read)
      {:error, :unexpected_availability_read}
    end
  end

  defmodule NoWriteBooker do
    def book(_slot, _ctx) do
      send(self(), :unexpected_booking_write)
      {:error, :unexpected_booking_write}
    end
  end

  setup do
    bypass = Bypass.open()
    old = Application.get_env(:lacuna, :backend_base_url)
    Application.put_env(:lacuna, :backend_base_url, "http://localhost:#{bypass.port}/")
    on_exit(fn -> Application.put_env(:lacuna, :backend_base_url, old) end)
    %{bypass: bypass}
  end

  test "public booking API fetches every upcoming page with the returned cursor", %{
    bypass: bypass
  } do
    Bypass.expect(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      offsets = body |> URI.decode_query() |> Map.fetch!("offset_details") |> Jason.decode!()

      data =
        case offsets do
          %{"upcoming_offset" => 0, "past_offset" => 0} -> page(booking("a"), 5, 15)
          %{"upcoming_offset" => 5, "past_offset" => 15} -> page(booking("b"), -1, 30)
        end

      Plug.Conn.resp(conn, 200, envelope(data))
    end)

    assert {:ok, data} = API.my_bookings(nil)
    assert Enum.map(data["my_bookings"]["Upcoming bookings"], & &1["booking_id"]) == ["a", "b"]
  end

  test "missing pagination metadata does not become a complete empty inventory", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      Plug.Conn.resp(conn, 200, envelope(%{"my_bookings" => %{}}))
    end)

    assert {:error, :incomplete_bookings} = API.my_bookings(nil)
  end

  for field <- ~w(type facility_id status start_date start_time end_time) do
    test "real paginator blocks the booking guard before any mutation when #{field} is missing",
         %{
           bypass: bypass
         } do
      row = Map.delete(booking("a"), unquote(field))

      Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
        Plug.Conn.resp(conn, 200, envelope(page(row, -1, -1)))
      end)

      assert {:error, :invalid_bookings} =
               Bookings.book(slot(), %{}, session: nil, api: GuardAPI, booker: NoWriteBooker)

      refute_receive :unexpected_availability_read
      refute_receive :unexpected_booking_write
    end
  end

  test "unknown nonempty approval statuses remain active and enforce the one-court guard", %{
    bypass: bypass
  } do
    row = Map.put(booking("a"), "status", "Awaiting committee review")

    Bypass.expect_once(bypass, "POST", "/facilities/m_get_my_bookings_v3", fn conn ->
      Plug.Conn.resp(conn, 200, envelope(page(row, -1, -1)))
    end)

    assert {:error, {:replacement_required, ^row}} =
             Bookings.book(slot(), %{}, session: nil, api: GuardAPI, booker: NoWriteBooker)

    refute_receive :unexpected_availability_read
    refute_receive :unexpected_booking_write
  end

  defp slot do
    %Slot{
      facility_id: "court-a",
      facility_name: "Court A",
      date: Date.add(Clock.local_today(), 1),
      start_time: ~T[12:00:00],
      end_time: ~T[13:00:00]
    }
  end

  defp booking(id),
    do: %{
      "booking_id" => id,
      "facility_id" => "court-a",
      "facility_name" => "Court A",
      "type" => "upcoming_bookings",
      "status" => "Booked",
      "start_date" => Calendar.strftime(Date.add(Clock.local_today(), 1), "%d-%b-%Y"),
      "start_time" => "10:00",
      "end_time" => "11:00"
    }

  defp page(row, upcoming, past),
    do: %{
      "my_bookings" => %{"Upcoming bookings" => [row]},
      "offset_details" => %{"upcoming_offset" => upcoming, "past_offset" => past}
    }

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
