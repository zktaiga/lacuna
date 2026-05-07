defmodule Lacuna.Telegram.WatchView do
  @moduledoc """
  `/watch` flow. One single, persistently-edited message that toggles the
  active watch on/off and exposes date, time-window, cutoff, and auto-book
  filters.

      ┌──────────────────────────────┐
      │ Watch: ON · until ∞          │
      │ Window: Evening (18–22)      │
      │ When: Today                  │
      │                              │
      │ [Toggle off]                 │
      │ Window: [M][A][E][Any]       │
      │ When:  [Today][Tomorrow][Weekend][Any] │
      │ Custom:[M][T][W][T][F][S][S] │
      │ Notice: [Last minute][T-30m][T-1h] │
      │ Action: [Alert][Auto-book]         │
      └──────────────────────────────┘

  The display always reflects the current `Lacuna.Watch.Config` state.
  """

  alias Lacuna.{Watch.Config, Slot}

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
    state =
      cond do
        not cfg.active? ->
          "🔘 *Off*"

        Config.matches?(%Slot{
          facility_id: "x",
          facility_name: "x",
          date: ~D[2099-01-01],
          start_time: ~T[12:00:00],
          end_time: ~T[13:00:00]
        }) ->
          "🟢 *On*"

        true ->
          "🟢 *On*"
      end

    ttl =
      case cfg.expires_at do
        nil ->
          if cfg.active?, do: "until you turn it off", else: "—"

        %DateTime{} = at ->
          local = at |> DateTime.add(4 * 3600, :second) |> DateTime.to_naive()
          "#{Calendar.strftime(local, "%a %d %b · %H:%M")}"
      end

    days = when_label(cfg)

    {lo, hi} = Config.window_range(cfg.window)
    cutoff = cutoff_label(cfg.stop_before_start_minutes)
    mode = if cfg.auto_book?, do: "auto-book first match", else: "send alert with Book button"

    """
    *Standing watch*

    Status:  #{state}
    Looking: #{days} · #{Config.window_label(cfg.window)} #{pad(lo)}:00–#{pad(hi)}:00
    Ends:    #{ttl}
    Notice:  #{cutoff}
    Action:  #{mode}
    """
  end

  defp render_markup(cfg) do
    toggle_text = if cfg.active?, do: "🔘 Turn off", else: "🟢 Turn on watch"

    rows =
      [
        # Toggle
        [%ExGram.Model.InlineKeyboardButton{text: toggle_text, callback_data: "watch:toggle"}],
        when_preset_row(cfg),
        weekdays_row(cfg, 0..3),
        weekdays_row(cfg, 4..6),
        windows_row(cfg),
        cutoff_row(cfg),
        mode_row(cfg),
        [
          %ExGram.Model.InlineKeyboardButton{text: "Done", callback_data: "watch:close"}
        ]
      ]

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows}
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
    text = if selected?, do: "✓ #{label}", else: label
    spec = if is_nil(preset), do: "any", else: to_string(preset)
    %ExGram.Model.InlineKeyboardButton{text: text, callback_data: "watch:when:#{spec}"}
  end

  defp windows_row(cfg) do
    for key <- [:morning, :afternoon, :evening, :any] do
      label = Config.window_label(key)
      display = if key == cfg.window, do: "✓ #{label}", else: label
      %ExGram.Model.InlineKeyboardButton{text: display, callback_data: "watch:w:#{key}"}
    end
  end

  defp weekdays_row(cfg, range) do
    @weekday_keys
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> i in range end)
    |> Enum.map(fn {day, _} ->
      on? = day in cfg.weekdays
      label = if on?, do: "✓#{day}", else: day
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
    text = if selected?, do: "✓ #{label}", else: label
    spec = if is_nil(value), do: "start", else: to_string(value)
    %ExGram.Model.InlineKeyboardButton{text: text, callback_data: "watch:cutoff:#{spec}"}
  end

  defp mode_row(cfg) do
    alert = if cfg.auto_book?, do: "🔔 Alert only", else: "✓ 🔔 Alert only"
    auto = if cfg.auto_book?, do: "✓ ⚡ Auto-book", else: "⚡ Auto-book"

    [
      %ExGram.Model.InlineKeyboardButton{text: alert, callback_data: "watch:auto:off"},
      %ExGram.Model.InlineKeyboardButton{text: auto, callback_data: "watch:auto:on"}
    ]
  end

  defp cutoff_label(nil), do: "last-minute, until slot starts"
  defp cutoff_label(30), do: "at least 30 minutes before start"
  defp cutoff_label(60), do: "at least 1 hour before start"
  defp cutoff_label(minutes), do: "#{minutes} minutes before slot start"

  defp when_label(%{date_preset: :today}), do: "Today"
  defp when_label(%{date_preset: :tomorrow}), do: "Tomorrow"
  defp when_label(%{date_preset: :weekend}), do: "Weekend"
  defp when_label(%{weekdays: []}), do: "Any day"
  defp when_label(%{weekdays: list}), do: Enum.join(list, ", ")

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
