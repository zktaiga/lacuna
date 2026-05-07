defmodule Lacuna.Telegram.WatchView do
  @moduledoc """
  `/watch` flow. One single, persistently-edited message that toggles the
  active watch on/off and exposes date, time-window, cutoff, and auto-book
  filters.

  The display always reflects the current `Lacuna.Watch.Config` state.
  """

  alias Lacuna.Watch.Config

  @weekday_keys ~w(Mon Tue Wed Thu Fri Sat Sun)

  ## Public

  def send_view(chat_id) do
    cfg = Config.get()

    ExGram.send_message(chat_id, render_text(cfg),
      parse_mode: "Markdown",
      reply_markup: render_markup(cfg)
    )

    :ok
  end

  def edit_view(message) do
    cfg = Config.get()

    ExGram.edit_message_text(render_text(cfg),
      chat_id: message.chat.id,
      message_id: message.message_id,
      parse_mode: "Markdown",
      reply_markup: render_markup(cfg)
    )
  end

  ## Render

  defp render_text(cfg) do
    title = if cfg.active?, do: "👀 *Standing watch is ON*", else: "👀 *Set up a watch*"
    hint = if cfg.active?, do: "", else: "\nNothing starts until you tap *Turn on watch*.\n"

    {lo, hi} = Config.window_range(cfg.window)

    """
    #{title}#{hint}
    🎯 #{when_label(cfg)} · #{String.downcase(Config.window_label(cfg.window))}
    🕕 #{pad(lo)}:00–#{pad(hi)}:00
    🔔 #{cutoff_label(cfg.stop_before_start_minutes)}
    ⏳ #{ends_label(cfg)}
    🧾 #{action_label(cfg)}
    """
  end

  defp render_markup(cfg) do
    toggle_text = if cfg.active?, do: "🔴 Turn off watch", else: "🟢 Turn on watch"

    rows = [
      section_row("When"),
      when_preset_row(cfg),
      section_row("Custom weekdays"),
      weekdays_row(cfg, 0..3),
      weekdays_row(cfg, 4..6),
      section_row("Time"),
      windows_row(cfg),
      section_row("Notice"),
      cutoff_row(cfg),
      section_row("Action"),
      mode_row(cfg),
      [%ExGram.Model.InlineKeyboardButton{text: toggle_text, callback_data: "watch:toggle"}],
      [%ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "watch:close"}]
    ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows}
  end

  defp section_row(label) do
    [%ExGram.Model.InlineKeyboardButton{text: "— #{label} —", callback_data: "watch:noop"}]
  end

  defp when_preset_row(cfg) do
    [
      preset_button(cfg, :today, "Today"),
      preset_button(cfg, :tomorrow, "Tomorrow"),
      preset_button(cfg, :weekend, "Weekend"),
      preset_button(cfg, nil, "Any")
    ]
  end

  defp preset_button(cfg, preset, label) do
    selected? = cfg.date_preset == preset and (not is_nil(preset) or cfg.weekdays == [])
    text = if selected?, do: "✅ #{label}", else: label
    spec = if is_nil(preset), do: "any", else: to_string(preset)
    %ExGram.Model.InlineKeyboardButton{text: text, callback_data: "watch:when:#{spec}"}
  end

  defp windows_row(cfg) do
    for key <- [:morning, :afternoon, :evening, :any] do
      label = Config.window_label(key)
      display = if key == cfg.window, do: "✅ #{label}", else: label
      %ExGram.Model.InlineKeyboardButton{text: display, callback_data: "watch:w:#{key}"}
    end
  end

  defp weekdays_row(cfg, range) do
    @weekday_keys
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> i in range end)
    |> Enum.map(fn {day, _} ->
      label = if day in cfg.weekdays, do: "✅ #{day}", else: day
      %ExGram.Model.InlineKeyboardButton{text: label, callback_data: "watch:days:#{day}"}
    end)
  end

  defp cutoff_row(cfg) do
    [
      cutoff_button(cfg, nil, "Last minute"),
      cutoff_button(cfg, 30, "T-30m"),
      cutoff_button(cfg, 60, "T-1h")
    ]
  end

  defp cutoff_button(cfg, value, label) do
    selected? = cfg.stop_before_start_minutes == value
    text = if selected?, do: "✅ #{label}", else: label
    spec = if is_nil(value), do: "start", else: to_string(value)
    %ExGram.Model.InlineKeyboardButton{text: text, callback_data: "watch:cutoff:#{spec}"}
  end

  defp mode_row(cfg) do
    alert = if cfg.auto_book?, do: "🔔 Alert only", else: "✅ 🔔 Alert only"
    auto = if cfg.auto_book?, do: "✅ ⚡ Auto-book", else: "⚡ Auto-book"

    [
      %ExGram.Model.InlineKeyboardButton{text: alert, callback_data: "watch:auto:off"},
      %ExGram.Model.InlineKeyboardButton{text: auto, callback_data: "watch:auto:on"}
    ]
  end

  defp cutoff_label(nil), do: "Alert: until slot starts"
  defp cutoff_label(30), do: "Alert: at least 30m before start"
  defp cutoff_label(60), do: "Alert: at least 1h before start"
  defp cutoff_label(minutes), do: "Alert: #{minutes}m before start"

  defp action_label(%{auto_book?: true}), do: "Action: auto-book first match"
  defp action_label(_cfg), do: "Action: send Book button"

  defp ends_label(%{date_preset: :today}), do: "Turns off tonight"
  defp ends_label(%{date_preset: :tomorrow}), do: "Turns off tomorrow night"
  defp ends_label(%{date_preset: :weekend}), do: "Turns off after Sunday"
  defp ends_label(_cfg), do: "Runs until you turn it off"

  defp when_label(%{date_preset: :today}), do: "Today"
  defp when_label(%{date_preset: :tomorrow}), do: "Tomorrow"
  defp when_label(%{date_preset: :weekend}), do: "Weekend"
  defp when_label(%{weekdays: []}), do: "Any day"
  defp when_label(%{weekdays: list}), do: Enum.join(list, ", ")

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
