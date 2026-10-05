defmodule Lacuna.Telegram.Callbacks do
  @moduledoc """
  Inline-button router. Four grammars:

  | Prefix         | Purpose                                |
  |----------------|----------------------------------------|
  | `free:…`       | `/free` day picker / time / court flow |
  | `watch:…`      | `/watch` standing-watch toggles        |
  | `bk:…`         | `/bookings` list / confirm / execute   |
  | `book:<key>`   | Book a slot from anywhere              |
  """

  alias Lacuna.{Bookings, Clock, Slot, Watch.Config}
  alias Lacuna.Bookings.Replacements
  alias Lacuna.Backend.{API, Availability, Session}
  alias Lacuna.Hunts.Settings
  alias Lacuna.Hunts.Store, as: HuntStore
  alias Lacuna.Telegram.{BookingsView, Free, HuntsView, Menu, Views, WatchView}
  require Logger

  def handle(%ExGram.Model.CallbackQuery{data: "f:" <> _ = data} = cq, ctx) do
    ack_free(data, cq)
    dispatch_free(data, cq)
    ctx
  end

  def handle(%ExGram.Model.CallbackQuery{data: "free:" <> _ = data} = cq, ctx) do
    ack_free(data, cq)
    dispatch_free(data, cq)
    ctx
  end

  def handle(%ExGram.Model.CallbackQuery{data: "replace:" <> _} = cq, ctx) do
    ExGram.answer_callback_query(cq.id, text: "Checking…")
    dispatch(cq.data, cq)
    ctx
  end

  def handle(%ExGram.Model.CallbackQuery{} = cq, ctx) do
    cq.data
    |> dispatch(cq)
    |> finalize(cq)

    ctx
  end

  ## Dispatch

  defp dispatch_free("f:" <> action, cq), do: dispatch_free_action(action, nil, cq)

  defp dispatch_free("free:v1:" <> rest, cq) do
    case String.split(rest, ":", parts: 2) do
      [_legacy_session_id, action] ->
        Logger.info("Legacy stateful /free callback translated to stateless action")
        dispatch_free_action(action, nil, cq)

      _ ->
        safe(fn -> Free.replace_expired(cq.message) end)
    end
  end

  defp dispatch_free("free:" <> legacy_action, cq),
    do: dispatch_free_action(legacy_action, nil, cq)

  defp dispatch_free_action("close", _session_id, cq) do
    safe(fn -> ExGram.delete_message(cq.message.chat.id, cq.message.message_id) end)
  end

  defp dispatch_free_action("root", session_id, cq),
    do: safe(fn -> Free.edit_to_root(cq.message, session_id) end)

  defp dispatch_free_action("d:" <> iso_date, session_id, cq) do
    case Date.from_iso8601(iso_date) do
      {:ok, date} -> safe(fn -> Free.edit_to_day(cq.message, session_id, date) end)
      _ -> :ok
    end
  end

  defp dispatch_free_action("t:" <> rest, session_id, cq) do
    with [iso_date, time_url] <- String.split(rest, ":", parts: 2),
         {:ok, date} <- Date.from_iso8601(iso_date),
         %Time{} = at <- parse_time_url(time_url) do
      safe(fn -> Free.edit_to_time(cq.message, session_id, date, at) end)
    else
      _ -> :ok
    end
  end

  defp dispatch_free_action(_, _session_id, _cq), do: :ok

  defp dispatch("menu:root", cq), do: safe(fn -> Menu.edit_menu(cq.message) end)
  defp dispatch("menu:free", cq), do: safe(fn -> Free.edit_to_root(cq.message) end)
  defp dispatch("menu:hunts", cq), do: safe(fn -> HuntsView.edit_list(cq.message) end)
  defp dispatch("menu:bookings", cq), do: safe(fn -> BookingsView.edit_to_list(cq.message) end)

  defp dispatch("hunt:list", cq), do: safe(fn -> HuntsView.edit_list(cq.message) end)
  defp dispatch("hunt:new", cq), do: safe(fn -> HuntsView.new_hunt(cq.message) end)
  defp dispatch("hunt:pace", cq), do: safe(fn -> HuntsView.edit_pace(cq.message) end)

  defp dispatch("hunt:pace:set:" <> profile, cq) do
    Settings.set_poll_profile(String.to_existing_atom(profile))
    safe(fn -> HuntsView.edit_list(cq.message) end)
    {:ack, "Pace updated"}
  end

  defp dispatch("hunt:show:" <> id, cq), do: safe(fn -> HuntsView.edit_detail(cq.message, id) end)
  defp dispatch("hunt:days:" <> id, cq), do: safe(fn -> HuntsView.edit_days(cq.message, id) end)
  defp dispatch("hunt:times:" <> id, cq), do: safe(fn -> HuntsView.edit_times(cq.message, id) end)

  defp dispatch("hunt:toggle:" <> id, cq) do
    HuntStore.toggle_active(id)
    safe(fn -> HuntsView.edit_detail(cq.message, id) end)
    {:ack, "Updated"}
  end

  defp dispatch("hunt:delete:" <> id, cq) do
    HuntStore.delete(id)
    safe(fn -> HuntsView.edit_list(cq.message) end)
    {:ack, "Deleted"}
  end

  defp dispatch("hunt:day:" <> rest, cq) do
    with [id, day] <- String.split(rest, ":", parts: 2) do
      HuntStore.toggle_day(id, day)
      safe(fn -> HuntsView.edit_days(cq.message, id) end)
      {:ack, "Updated"}
    else
      _ -> :ok
    end
  end

  defp dispatch("hunt:time:" <> rest, cq) do
    with [id, time_text] <- String.split(rest, ":", parts: 2),
         %Time{} = time <- parse_time_url(String.replace(time_text, ":", "-")) do
      HuntStore.toggle_time(id, time)
      safe(fn -> HuntsView.edit_times(cq.message, id) end)
      {:ack, "Updated"}
    else
      _ -> :ok
    end
  end

  defp dispatch("hunt:mode:set:" <> rest, cq) do
    with [id, mode] <- String.split(rest, ":", parts: 2) do
      HuntStore.set_mode(id, String.to_existing_atom(mode))
      safe(fn -> HuntsView.edit_mode(cq.message, id) end)
      {:ack, "Updated"}
    else
      _ -> :ok
    end
  end

  defp dispatch("hunt:after:set:" <> rest, cq) do
    with [id, after_match] <- String.split(rest, ":", parts: 2) do
      HuntStore.set_after_match(id, String.to_existing_atom(after_match))
      safe(fn -> HuntsView.edit_after(cq.message, id) end)
      {:ack, "Updated"}
    else
      _ -> :ok
    end
  end

  defp dispatch("hunt:mode:" <> id, cq), do: safe(fn -> HuntsView.edit_mode(cq.message, id) end)
  defp dispatch("hunt:after:" <> id, cq), do: safe(fn -> HuntsView.edit_after(cq.message, id) end)

  defp dispatch("free:close", cq) do
    safe(fn -> ExGram.delete_message(cq.message.chat.id, cq.message.message_id) end)
    {:ack, "Closed"}
  end

  defp dispatch("free:root", cq), do: safe(fn -> Free.edit_to_root(cq.message) end)

  defp dispatch("free:d:" <> iso_date, cq) do
    case Date.from_iso8601(iso_date) do
      {:ok, date} -> safe(fn -> Free.edit_to_day(cq.message, date) end)
      _ -> :ok
    end
  end

  defp dispatch("free:t:" <> rest, cq) do
    with [iso_date, time_url] <- String.split(rest, ":", parts: 2),
         {:ok, date} <- Date.from_iso8601(iso_date),
         %Time{} = at <- parse_time_url(time_url) do
      safe(fn -> Free.edit_to_time(cq.message, date, at) end)
    else
      _ -> :ok
    end
  end

  defp dispatch("watch:noop", _cq), do: :ok

  defp dispatch("watch:close", cq) do
    safe(fn ->
      ExGram.delete_message(cq.message.chat.id, cq.message.message_id)
    end)

    {:ack, "Closed"}
  end

  defp dispatch("watch:toggle", cq) do
    cfg = Config.get()
    if cfg.active?, do: Config.disable(), else: Config.enable()
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, "Watch updated"}
  end

  defp dispatch("watch:w:" <> key, cq) do
    Config.set_window(String.to_atom(key))
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:when:any", cq) do
    Config.set_date_preset(nil)
    Config.set_expires(nil)
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:when:" <> preset, cq) do
    Config.set_date_preset(String.to_existing_atom(preset))
    Config.set_expires(expires_for_preset(preset))
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:days:any", cq) do
    Config.set_weekdays([])
    Config.set_expires(nil)
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:days:" <> day, cq) do
    cfg = Config.get()

    new_list =
      if day in cfg.weekdays,
        do: List.delete(cfg.weekdays, day),
        else: cfg.weekdays ++ [day]

    Config.set_weekdays(new_list)
    Config.set_expires(nil)
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:cutoff:" <> spec, cq) do
    minutes = if spec == "start", do: nil, else: String.to_integer(spec)
    Config.set_stop_before_start(minutes)
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, "Cutoff set"}
  end

  defp dispatch("watch:auto:" <> spec, cq) do
    Config.set_auto_book(spec == "on")
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, if(spec == "on", do: "Auto-book on", else: "Alert only")}
  end

  defp dispatch("watch:ttl:" <> spec, cq) do
    expires =
      case spec do
        "none" -> nil
        "today" -> local_end_of_day(0)
        "tomorrow" -> local_end_of_day(1)
        "7d" -> local_end_of_day(6)
        _ -> nil
      end

    Config.set_expires(expires)
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, "Ends set"}
  end

  defp dispatch("bk:list", cq), do: safe(fn -> BookingsView.edit_to_list(cq.message) end)

  defp dispatch("bk:v:" <> id, cq),
    do: safe(fn -> BookingsView.edit_to_details(cq.message, id) end)

  defp dispatch("bk:c:" <> id, cq),
    do: safe(fn -> BookingsView.edit_to_confirm(cq.message, id) end)

  defp dispatch("bk:do:" <> id, cq),
    do: safe(fn -> BookingsView.execute_cancel(cq.message, id) end)

  defp dispatch("replace:yes:" <> token, cq), do: do_replace(cq, token)

  defp dispatch("replace:keep:" <> token, cq) do
    case Replacements.discard(token, replacement_owner(cq)) do
      {:ok, intent} ->
        Free.edit_to_time(cq.message, intent.slot.date, intent.slot.start_time)

      {:error, :replacement_wrong_actor} ->
        :ok

      _ ->
        edit_message(
          cq,
          "This confirmation expired or was already used. Reopen /free or /bookings.",
          reply_markup: menu_keyboard()
        )
    end
  end

  defp dispatch("book:" <> key, cq), do: do_book(cq, key)

  defp dispatch(_, _cq), do: :unknown

  ## Booking

  defp do_book(cq, slot_key) do
    show_booking_in_progress(cq)

    case String.split(slot_key, "|") do
      [facility_id, date_iso, time_iso] ->
        with {:ok, date} <- Date.from_iso8601(date_iso),
             {:ok, time} <- Time.from_iso8601(time_iso),
             {:ok, %Slot{} = slot} <- rebuild_slot(facility_id, date, time) do
          result = Bookings.book(slot, %{actor: cq.from})
          reply_book(cq, slot, result)
          {:ack, ack_text(result)}
        else
          {:error, reason} ->
            edit_message(cq, "❌ Slot no longer fetchable: `#{trunc_inspect(reason)}`")
            {:ack, "Failed", true}

          _ ->
            {:ack, "Bad slot key", true}
        end

      _ ->
        {:ack, "Bad slot key", true}
    end
  end

  defp rebuild_slot(facility_id, date, time) do
    session = Session.current!()

    with {:ok, details} <- API.facility_availability(session, facility_id, date) do
      slot =
        details
        |> Map.put_new("facility_id", facility_id)
        |> Map.delete("booked_slots_on_date")
        |> Map.delete("slot_availability")
        |> Availability.open_slots(date)
        |> Enum.find(fn s -> Time.compare(s.start_time, time) == :eq end)

      if slot, do: {:ok, slot}, else: {:error, :slot_no_longer_open}
    end
  end

  defp do_replace(cq, token) do
    case Replacements.take(token, replacement_owner(cq)) do
      {:ok, intent} ->
        edit_message(cq, "⏳ Rechecking the target and existing booking…",
          reply_markup: empty_keyboard()
        )

        result =
          Bookings.replace(intent.slot, intent.booking_id, %{actor: cq.from},
            expected_booking: intent.expected_booking
          )

        case result do
          {:ok, _} ->
            reply_book(cq, intent.slot, result)

          {:error, reason} ->
            edit_message(cq, "Replacement stopped.\n" <> Bookings.error_text(reason),
              reply_markup: menu_keyboard()
            )
        end

      {:error, :replacement_wrong_actor} ->
        :ok

      _ ->
        edit_message(
          cq,
          "This confirmation expired or was already used. Nothing else was cancelled. Reopen /free or /bookings.",
          reply_markup: menu_keyboard()
        )
    end
  end

  defp replacement_owner(cq), do: {cq.from && cq.from.id, cq.message.chat.id}

  defp empty_keyboard, do: %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: []}

  defp menu_keyboard do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [%ExGram.Model.InlineKeyboardButton{text: "← Menu", callback_data: "menu:root"}]
      ]
    }
  end

  defp reply_book(cq, %Slot{} = slot, {:error, {:replacement_required, booking}}) do
    case Replacements.prepare(slot, booking, replacement_owner(cq)) do
      {:ok, token} ->
        text = Views.replacement_text(slot, booking)

        keyboard = %ExGram.Model.InlineKeyboardMarkup{
          inline_keyboard: [
            [
              %ExGram.Model.InlineKeyboardButton{
                text: "Confirm replacement",
                callback_data: "replace:yes:" <> token
              },
              %ExGram.Model.InlineKeyboardButton{
                text: "← Courts",
                callback_data: "replace:keep:" <> token
              }
            ]
          ]
        }

        edit_message(cq, text, reply_markup: keyboard)

      {:error, reason} ->
        edit_message(cq, Bookings.error_text(reason), reply_markup: menu_keyboard())
    end
  end

  defp reply_book(cq, %Slot{}, {:error, {:already_booked, booking}}) do
    edit_message(cq, "✅ Already booked: " <> Bookings.summary(booking),
      reply_markup: menu_keyboard()
    )
  end

  defp reply_book(cq, %Slot{} = slot, {:ok, _booking}) do
    actor = display_user(cq.from)
    text = "✅ Booked: #{Views.render_slot(slot)} · by #{actor}"

    case publish_booking_receipt(cq, text) do
      :ok -> :ok
      {:error, _reason} -> edit_message(cq, text)
    end
  end

  defp reply_book(cq, %Slot{} = slot, {:error, reason}) do
    edit_message(
      cq,
      "❌ Booking failed: #{Views.render_slot(slot)}\n#{format_booking_error(reason)}"
    )
  end

  defp ack_text({:ok, _}), do: "Booked!"
  defp ack_text({:error, {:replacement_required, _}}), do: "Review replacement"
  defp ack_text({:error, {:already_booked, _}}), do: "Already booked"
  defp ack_text({:error, _}), do: "Failed"

  defp format_booking_error(reason), do: Bookings.error_text(reason)

  defp show_booking_in_progress(cq) do
    empty_keyboard = %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: []}
    edit_message(cq, "⏳ Checking availability and booking…", reply_markup: empty_keyboard)
  end

  defp publish_booking_receipt(
         %ExGram.Model.CallbackQuery{message: %{chat: %{id: chat_id}, message_id: message_id}},
         text
       ),
       do: Lacuna.Telegram.BookingReceipt.publish(chat_id, message_id, text)

  defp publish_booking_receipt(_, _text), do: {:error, :missing_callback_message}

  ## Helpers

  defp expires_for_preset("today"), do: local_end_of_day(0)
  defp expires_for_preset("tomorrow"), do: local_end_of_day(1)
  defp expires_for_preset("weekend"), do: weekend_end()

  defp weekend_end do
    today = Clock.local_today()
    days_until_sunday = rem(7 - Date.day_of_week(today), 7)
    local_end_of_day(days_until_sunday)
  end

  defp local_end_of_day(days_from_today) do
    Clock.local_today()
    |> Date.add(days_from_today)
    |> NaiveDateTime.new!(~T[23:59:59])
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(-4 * 3600, :second)
  end

  defp parse_time_url(s) do
    case String.split(s, "-") do
      [h, m] -> Time.new!(String.to_integer(h), String.to_integer(m), 0)
      [h] -> Time.new!(String.to_integer(h), 0, 0)
      _ -> nil
    end
  end

  defp safe(fun) do
    try do
      fun.()
      :ok
    rescue
      e ->
        Logger.error("Callback handler raised: #{Exception.message(e)}")
        :error
    end
  end

  defp edit_message(cq, text, opts \\ [])

  defp edit_message(
         %ExGram.Model.CallbackQuery{message: %{chat: %{id: cid}, message_id: mid}},
         text,
         opts
       ) do
    ExGram.edit_message_text(
      text,
      Keyword.merge([chat_id: cid, message_id: mid, parse_mode: "Markdown"], opts)
    )
  end

  defp edit_message(_, _, _), do: :ok

  defp display_user(%{username: u}) when is_binary(u) and u != "", do: "@" <> u
  defp display_user(%{first_name: f}) when is_binary(f) and f != "", do: f
  defp display_user(_), do: "someone"

  defp trunc_inspect(t), do: t |> inspect() |> String.slice(0, 200)

  ## Telegram callback ack — always answer, never leave the spinner

  defp ack_free("f:" <> action, cq) do
    text = if action == "close", do: "Closed", else: "Refreshing…"
    ExGram.answer_callback_query(cq.id, text: text)
  end

  defp ack_free("free:v1:" <> rest, cq) do
    text = if String.ends_with?(rest, ":close"), do: "Closed", else: "Refreshing…"
    ExGram.answer_callback_query(cq.id, text: text)
  end

  defp ack_free("free:" <> action, cq) do
    text = if action == "close", do: "Closed", else: "Refreshing…"
    ExGram.answer_callback_query(cq.id, text: text)
  end

  defp finalize({:ack, text}, cq), do: ExGram.answer_callback_query(cq.id, text: text)

  defp finalize({:ack, text, true}, cq),
    do: ExGram.answer_callback_query(cq.id, text: text, show_alert: true)

  defp finalize(:unknown, cq), do: ExGram.answer_callback_query(cq.id, text: "Unknown action.")
  defp finalize(_, cq), do: ExGram.answer_callback_query(cq.id)
end
