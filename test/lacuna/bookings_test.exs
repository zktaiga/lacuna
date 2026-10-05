defmodule Lacuna.BookingsTest do
  use ExUnit.Case, async: false
  alias Lacuna.{Bookings, Slot}
  alias Lacuna.Backend.Cache
  alias Lacuna.Bookings.Replacements

  defmodule Backend do
    def my_bookings(pid) do
      Agent.get_and_update(pid, fn s ->
        data = if s[:malformed], do: %{}, else: %{"my_bookings" => %{"0" => s.bookings}}
        {{:ok, data}, %{s | calls: s.calls ++ [:read_bookings]}}
      end)
    end

    def facility_availability(pid, _, _) do
      Agent.get_and_update(pid, fn s ->
        {{:ok, s.availability}, %{s | calls: s.calls ++ [:read_availability]}}
      end)
    end

    def cancel_booking(pid, id) do
      Agent.get_and_update(pid, fn s ->
        if s.cancel_error do
          {{:error, s.cancel_error}, %{s | calls: s.calls ++ [{:cancel, id}]}}
        else
          {{:ok, %{}},
           %{
             s
             | bookings: Enum.reject(s.bookings, &(&1["booking_id"] == id)),
               calls: s.calls ++ [{:cancel, id}]
           }}
        end
      end)
    end
  end

  defmodule Booker do
    def book(slot, %{test_pid: pid} = ctx) do
      if ctx[:raise], do: raise("test failure after cancellation")

      if owner = ctx[:barrier] do
        send(owner, {:booker_waiting, self()})

        receive do
          :continue -> :ok
        after
          2_000 -> raise "test barrier timeout"
        end
      end

      Agent.get_and_update(pid, fn s ->
        result = s.book_result || {:ok, %{slot: slot, booking: %{"booking_id" => "new"}}}

        bookings =
          if match?({:ok, _}, result),
            do: s.bookings ++ [Lacuna.BookingsTest.booking("new", "court-a", "18:00")],
            else: s.bookings

        {result, %{s | calls: s.calls ++ [:book], bookings: bookings}}
      end)
    end
  end

  setup do
    start_supervised!(Cache)
    start_supervised!(Replacements)

    pid =
      start_supervised!(
        {Agent,
         fn ->
           %{
             bookings: [booking()],
             calls: [],
             cancel_error: nil,
             book_result: nil,
             availability: %{
               "facility_id" => "court-a",
               "facility_name" => "Court A",
               "is_facility_fixed_slot_based" => "1",
               "fixed_time_slots" => %{"slot-18" => "18:00 - 19:00"},
               "booked_slots_on_date" => []
             }
           }
         end}
      )

    %{pid: pid, slot: slot(), opts: [api: Backend, session: pid, booker: Booker]}
  end

  test "a reservation blocks only its court and identifies an already-held slot", %{slot: slot} do
    old = booking()
    assert {:replacement_required, ^old} = Bookings.eligibility(slot, [old])

    assert :bookable =
             Bookings.eligibility(%{slot | facility_id: "court-b", facility_name: "Court B"}, [
               old
             ])

    assert {:already_booked, ^old} =
             Bookings.eligibility(%{slot | start_time: ~T[19:00:00], end_time: ~T[20:00:00]}, [
               old
             ])

    assert :bookable = Bookings.eligibility(slot, [Map.put(old, "status", "Cancelled")])
  end

  test "numeric court IDs remain authoritative", %{slot: slot} do
    old = booking() |> Map.put("facility_id", 42) |> Map.put("facility_name", "Different name")

    assert {:replacement_required, ^old} =
             Bookings.eligibility(%{slot | facility_id: "42"}, [old])

    assert :bookable =
             Bookings.eligibility(%{slot | facility_id: "43", facility_name: "Different name"}, [
               old
             ])
  end

  test "changed same-ID reservation invalidates replacement consent", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    expected = Bookings.snapshot(booking())

    Agent.update(
      pid,
      &%{
        &1
        | bookings: [booking("old", "court-a", "18:00") |> Map.put("start_date", "14-Oct-2099")]
      }
    )

    assert {:error, :existing_booking_changed} =
             Bookings.replace(
               slot,
               "old",
               %{test_pid: pid},
               Keyword.put(opts, :expected_booking, expected)
             )

    assert Agent.get(pid, & &1.calls) == [:read_bookings]
  end

  test "browsing includes only owned unavailable slots", %{pid: pid, slot: slot} do
    details =
      Agent.get(pid, & &1.availability)
      |> Map.put("slot_availability", %{"slot-18" => %{"is_available" => false}})

    assert Bookings.browsing_slots(details, slot.date, []) == []

    assert [held] =
             Bookings.browsing_slots(details, slot.date, [booking("mine", "court-a", "18:00")])

    assert {:already_booked, _} =
             Bookings.eligibility(held, [booking("mine", "court-a", "18:00")])
  end

  test "malformed bookings fail closed without writes", %{pid: pid, slot: slot, opts: opts} do
    Agent.update(pid, &Map.put(&1, :malformed, true))
    assert {:error, :invalid_bookings} = Bookings.book(slot, %{test_pid: pid}, opts)
    assert {:error, :invalid_bookings} = Bookings.replace(slot, "old", %{test_pid: pid}, opts)
    assert Agent.get(pid, & &1.calls) == [:read_bookings, :read_bookings]
  end

  test "past and rejected records do not block a court", %{slot: slot} do
    assert :bookable =
             Bookings.eligibility(slot, [Map.put(booking(), "start_date", "13-Oct-2000")])

    assert :bookable = Bookings.eligibility(slot, [Map.put(booking(), "status", "Rejected")])
  end

  test "post-cancellation exception reports partial outcome", %{pid: pid, slot: slot, opts: opts} do
    assert {:error, {:replacement_failed, :old_booking_cancelled, :replacement_booking_exception}} =
             Bookings.replace(slot, "old", %{test_pid: pid, raise: true}, opts)

    assert Agent.get(pid, & &1.bookings) == []
  end

  test "ordinary and automatic booking never cancel an existing reservation", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    assert {:error, {:replacement_required, _}} =
             Bookings.book(slot, %{actor: :hunt_auto_book, test_pid: pid}, opts)

    assert Agent.get(pid, & &1.calls) == [:read_bookings]
  end

  test "replacement rechecks availability before verified cancellation and booking", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    assert {:ok, %{replaced_booking: %{"booking_id" => "old"}}} =
             Bookings.replace(slot, "old", %{test_pid: pid}, opts)

    assert Agent.get(pid, & &1.calls) == [
             :read_bookings,
             :read_availability,
             {:cancel, "old"},
             :book
           ]
  end

  test "lost target or changed reservation preserves the original booking", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    assert {:error, :existing_booking_changed} =
             Bookings.replace(slot, "different", %{test_pid: pid}, opts)

    Agent.update(pid, fn s ->
      %{
        s
        | calls: [],
          availability:
            Map.put(s.availability, "booked_slots_on_date", [
              %{"start_time" => "18:00", "duration" => 60}
            ])
      }
    end)

    assert {:error, :slot_no_longer_open} = Bookings.replace(slot, "old", %{test_pid: pid}, opts)
    assert Agent.get(pid, & &1.calls) == [:read_bookings, :read_availability]
    assert Agent.get(pid, &length(&1.bookings)) == 1
  end

  test "unverified cancellation never proceeds to booking", %{pid: pid, slot: slot, opts: opts} do
    Agent.update(pid, &%{&1 | cancel_error: :cancellation_not_confirmed})

    assert {:error, :cancellation_not_confirmed} =
             Bookings.replace(slot, "old", %{test_pid: pid}, opts)

    refute :book in Agent.get(pid, & &1.calls)
  end

  test "replacement failure explicitly records that the original was cancelled", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    Agent.update(pid, &%{&1 | book_result: {:error, :slot_taken}})

    assert {:error, {:replacement_failed, :old_booking_cancelled, :slot_taken}} =
             Bookings.replace(slot, "old", %{test_pid: pid}, opts)

    assert Bookings.error_text({:replacement_failed, :old_booking_cancelled, :slot_taken}) =~
             "old booking was cancelled"
  end

  test "a repeated replacement cannot cancel or book twice", %{pid: pid, slot: slot, opts: opts} do
    assert {:ok, _} = Bookings.replace(slot, "old", %{test_pid: pid}, opts)

    assert {:error, :existing_booking_changed} =
             Bookings.replace(slot, "old", %{test_pid: pid}, opts)

    assert Enum.count(Agent.get(pid, & &1.calls), &(&1 == {:cancel, "old"})) == 1
    assert Enum.count(Agent.get(pid, & &1.calls), &(&1 == :book)) == 1
  end

  test "manual replacement and another mutation cannot interleave", %{
    pid: pid,
    slot: slot,
    opts: opts
  } do
    owner = self()

    first =
      Task.async(fn -> Bookings.replace(slot, "old", %{test_pid: pid, barrier: owner}, opts) end)

    assert_receive {:booker_waiting, worker}

    second =
      Task.async(fn ->
        send(owner, :second_started)
        Bookings.replace(slot, "old", %{test_pid: pid}, opts)
      end)

    assert_receive :second_started
    send(worker, :continue)
    assert {:ok, _} = Task.await(first)
    assert {:error, :existing_booking_changed} = Task.await(second)
    assert Enum.count(Agent.get(pid, & &1.calls), &(&1 == {:cancel, "old"})) == 1
    assert Enum.count(Agent.get(pid, & &1.calls), &(&1 == :book)) == 1
  end

  test "confirmation is short, owner-bound and consumed only once", %{slot: slot} do
    assert {:ok, token} = Replacements.prepare(slot, booking(), {7, 9})
    assert byte_size("replace:yes:" <> token) <= 64
    assert {:error, :replacement_wrong_actor} = Replacements.take(token, {8, 9})
    assert {:error, :replacement_wrong_actor} = Replacements.take(token, {7, 10})
    assert {:ok, %{booking_id: "old"}} = Replacements.take(token, {7, 9})
    assert {:error, :replacement_expired} = Replacements.take(token, {7, 9})
  end

  test "keep current booking discards the replacement without backend writes", %{
    pid: pid,
    slot: slot
  } do
    {:ok, token} = Replacements.prepare(slot, booking(), {7, 9})
    assert {:ok, _} = Replacements.discard(token, {7, 9})
    assert {:error, :replacement_expired} = Replacements.take(token, {7, 9})
    assert Agent.get(pid, & &1.calls) == []
  end

  test "the shared keyboard distinguishes replacement and available courts", %{slot: slot} do
    alias Lacuna.Telegram.Views
    assert Views.booking_button(slot, {:ok, [booking()]}).text =~ "Replace…"

    assert Views.booking_button(
             %{slot | facility_id: "court-b", facility_name: "Court B"},
             {:ok, [booking()]}
           ).text =~ "· Book"

    assert Views.booking_button(slot, {:error, :unavailable}).text =~ "Check & book"
  end

  test "court buttons omit the selected time and use readable court names", %{slot: slot} do
    alias Lacuna.Telegram.Views
    slot = %{slot | facility_name: "Neighborhood 3  -Padel Court 2"}

    assert Views.booking_button(slot, {:ok, [booking()]}, show_time: false).text ==
             "Neighborhood 3 / Court 2 · Replace…"

    assert Views.court_label("Neighborhood 1 - Padel Court") == "Neighborhood 1"

    assert Views.booking_button(
             %{slot | start_time: ~T[19:00:00], end_time: ~T[20:00:00]},
             {:ok, [booking()]}, show_time: false).text == "Neighborhood 3 / Court 2 · Already yours ✓"
  end

  test "replacement text lists the court once and distinguishes current and new", %{slot: slot} do
    text = Lacuna.Telegram.Views.replacement_text(slot, booking())
    assert text =~ "*Current:* Tue 13 Oct · 19:00–20:00"
    assert text =~ "*New:* Tue 13 Oct · 18:00–19:00"
    assert text =~ "you could lose both"
    assert length(String.split(text, "Court A")) == 2
  end

  def booking(id \\ "old", court \\ "court-a", time \\ "19:00") do
    end_time = if time == "19:00", do: "20:00", else: "19:00"

    %{
      "booking_id" => id,
      "facility_id" => court,
      "facility_name" => "Court A",
      "type" => "upcoming_bookings",
      "status" => "Booked",
      "start_date" => "13-Oct-2099",
      "start_time" => time,
      "end_time" => end_time
    }
  end

  defp slot,
    do: %Slot{
      facility_id: "court-a",
      facility_name: "Court A",
      date: ~D[2099-10-13],
      start_time: ~T[18:00:00],
      end_time: ~T[19:00:00],
      slot_id: "slot-18",
      fee_aed: 0
    }
end
