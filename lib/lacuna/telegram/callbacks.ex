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

  alias Lacuna.{Slot, Watch.Config}
  alias Lacuna.Backend.{API, Availability, Session}
  alias Lacuna.Telegram.{Free, WatchView, BookingsView, Views}
  require Logger

  def handle(%ExGram.Model.CallbackQuery{} = cq, ctx) do
    cq.data
    |> dispatch(cq)
    |> finalize(cq)

    ctx
  end

  ## Dispatch

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

  defp dispatch("watch:days:any", cq) do
    Config.set_weekdays([])
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
    safe(fn -> WatchView.edit_view(cq.message) end)
    :ok
  end

  defp dispatch("watch:cutoff:" <> spec, cq) do
    minutes = if spec == "start", do: nil, else: String.to_integer(spec)
    Config.set_stop_before_start(minutes)
    if Config.get().active? == false, do: Config.enable()
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, "Cutoff set"}
  end

  defp dispatch("watch:auto:" <> spec, cq) do
    Config.set_auto_book(spec == "on")
    if Config.get().active? == false, do: Config.enable()
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, if(spec == "on", do: "Auto-book on", else: "Alert only")}
  end

  defp dispatch("watch:ttl:" <> spec, cq) do
    expires =
      case spec do
        "none" -> nil
        "2h" -> DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
        "12h" -> DateTime.add(DateTime.utc_now(), 12 * 3600, :second)
        "24h" -> DateTime.add(DateTime.utc_now(), 24 * 3600, :second)
        _ -> nil
      end

    Config.set_expires(expires)
    if Config.get().active? == false, do: Config.enable()
    safe(fn -> WatchView.edit_view(cq.message) end)
    {:ack, "TTL set"}
  end

  defp dispatch("bk:list", cq), do: safe(fn -> BookingsView.edit_to_list(cq.message) end)

  defp dispatch("bk:c:" <> id, cq),
    do: safe(fn -> BookingsView.edit_to_confirm(cq.message, id) end)

  defp dispatch("bk:do:" <> id, cq),
    do: safe(fn -> BookingsView.execute_cancel(cq.message, id) end)

  defp dispatch("book:" <> key, cq), do: do_book(cq, key)

  defp dispatch(_, _cq), do: :unknown

  ## Booking

  defp do_book(cq, slot_key) do
    case String.split(slot_key, "|") do
      [facility_id, date_iso, time_iso] ->
        with {:ok, date} <- Date.from_iso8601(date_iso),
             {:ok, time} <- Time.from_iso8601(time_iso),
             {:ok, %Slot{} = slot} <- rebuild_slot(facility_id, date, time) do
          prefs = Lacuna.Config.load!()
          booker = prefs.plugins.booker || Lacuna.Plugins.DefaultBooker

          result = apply(booker, :book, [slot, %{actor: cq.from}])
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
        |> Availability.open_slots(date)
        |> Enum.find(fn s -> Time.compare(s.start_time, time) == :eq end)

      if slot, do: {:ok, slot}, else: {:error, :slot_no_longer_open}
    end
  end

  defp reply_book(cq, %Slot{} = slot, {:ok, _booking}) do
    actor = display_user(cq.from)
    edit_message(cq, "✅ Booked: #{Views.render_slot(slot)} · by #{actor}")
  end

  defp reply_book(cq, %Slot{} = slot, {:error, reason}) do
    edit_message(cq, "❌ Booking failed: #{Views.render_slot(slot)}\n`#{trunc_inspect(reason)}`")
  end

  defp ack_text({:ok, _}), do: "Booked!"
  defp ack_text({:error, _}), do: "Failed"

  ## Helpers

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

  defp edit_message(
         %ExGram.Model.CallbackQuery{message: %{chat: %{id: cid}, message_id: mid}},
         text
       ) do
    ExGram.edit_message_text(text, chat_id: cid, message_id: mid, parse_mode: "Markdown")
  end

  defp edit_message(_, _), do: :ok

  defp display_user(%{username: u}) when is_binary(u) and u != "", do: "@" <> u
  defp display_user(%{first_name: f}) when is_binary(f) and f != "", do: f
  defp display_user(_), do: "someone"

  defp trunc_inspect(t), do: t |> inspect() |> String.slice(0, 200)

  ## Telegram callback ack — always answer, never leave the spinner

  defp finalize({:ack, text}, cq), do: ExGram.answer_callback_query(cq.id, text: text)

  defp finalize({:ack, text, true}, cq),
    do: ExGram.answer_callback_query(cq.id, text: text, show_alert: true)

  defp finalize(:unknown, cq), do: ExGram.answer_callback_query(cq.id, text: "Unknown action.")
  defp finalize(_, cq), do: ExGram.answer_callback_query(cq.id)
end
