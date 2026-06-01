defmodule Lacuna.Telegram.HuntsView do
  @moduledoc "Telegram UI for multiple standing hunts."

  alias Lacuna.Hunts.{Hunt, Settings, Store}
  alias Lacuna.Telegram.Views

  @weekday_keys Hunt.weekday_keys()

  def send_list(chat_id) do
    ExGram.send_message(chat_id, list_text(), parse_mode: "Markdown", reply_markup: list_markup())
    :ok
  end

  def edit_list(message) do
    ExGram.edit_message_text(list_text(),
      chat_id: message.chat.id,
      message_id: message.message_id,
      parse_mode: "Markdown",
      reply_markup: list_markup()
    )
  end

  def edit_detail(message, id) do
    case Store.get(id) do
      nil -> edit_list(message)
      hunt -> edit(message, detail_text(hunt), detail_markup(hunt))
    end
  end

  def new_hunt(message) do
    case Store.create_default() do
      {:ok, hunt} ->
        edit_detail(message, hunt.id)

      {:error, :max_active_hunts} ->
        edit(message, "⚠️ You already have the maximum number of active hunts.", list_markup())
    end
  end

  def edit_days(message, id), do: edit_picker(message, id, :days)
  def edit_times(message, id), do: edit_picker(message, id, :times)
  def edit_mode(message, id), do: edit_picker(message, id, :mode)
  def edit_after(message, id), do: edit_picker(message, id, :after)

  def edit_pace(message) do
    edit(message, "🎛 *Polling pace*\n\n#{pace_help_text()}", pace_markup())
  end

  defp edit_picker(message, id, picker) do
    case Store.get(id) do
      nil -> edit_list(message)
      hunt -> edit(message, detail_text(hunt), picker_markup(hunt, picker))
    end
  end

  defp list_text do
    hunts = Store.list()

    body =
      if hunts == [] do
        "No hunts yet. Tap ➕ *New hunt* to watch for matching slots."
      else
        hunts
        |> Enum.map_join("\n\n", fn hunt ->
          "#{status(hunt)} *#{escape(hunt.name)}*\n#{summary(hunt)}"
        end)
      end

    "🎯 *Hunts*\n\n#{body}\n\n#{pace_text()}"
  end

  defp list_markup do
    hunt_rows =
      Store.list()
      |> Enum.map(fn hunt ->
        [
          %ExGram.Model.InlineKeyboardButton{
            text: "#{status(hunt)} #{hunt.name}",
            callback_data: "hunt:show:#{hunt.id}"
          }
        ]
      end)

    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard:
        hunt_rows ++
          [
            [
              %ExGram.Model.InlineKeyboardButton{
                text: "#{pace_button_text()}",
                callback_data: "hunt:pace"
              }
            ],
            [%ExGram.Model.InlineKeyboardButton{text: "➕ New hunt", callback_data: "hunt:new"}]
          ]
    }
  end

  defp detail_text(hunt) do
    blocked =
      if hunt.blocked_reason, do: "\n⚠️ Blocked: #{blocked_label(hunt.blocked_reason)}", else: ""

    """
    🎯 *#{escape(hunt.name)}*

    Status: #{status(hunt)}
    #{summary(hunt)}#{blocked}
    """
  end

  defp detail_markup(hunt) do
    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{
            text: "📅 Days",
            callback_data: "hunt:days:#{hunt.id}"
          },
          %ExGram.Model.InlineKeyboardButton{
            text: "🕒 Times",
            callback_data: "hunt:times:#{hunt.id}"
          }
        ],
        [
          %ExGram.Model.InlineKeyboardButton{
            text: "🔔 Mode",
            callback_data: "hunt:mode:#{hunt.id}"
          },
          %ExGram.Model.InlineKeyboardButton{
            text: "🎬 After match",
            callback_data: "hunt:after:#{hunt.id}"
          }
        ],
        [
          %ExGram.Model.InlineKeyboardButton{
            text: if(hunt.active?, do: "⏸ Pause", else: "▶️ Resume"),
            callback_data: "hunt:toggle:#{hunt.id}"
          },
          %ExGram.Model.InlineKeyboardButton{
            text: "🗑 Delete",
            callback_data: "hunt:delete:#{hunt.id}"
          }
        ],
        [%ExGram.Model.InlineKeyboardButton{text: "← Back", callback_data: "hunt:list"}]
      ]
    }
  end

  defp picker_markup(hunt, :days) do
    rows =
      @weekday_keys
      |> Enum.map(fn day ->
        label = if day in hunt.weekdays, do: "✅ #{day}", else: day

        %ExGram.Model.InlineKeyboardButton{
          text: label,
          callback_data: "hunt:day:#{hunt.id}:#{day}"
        }
      end)
      |> Enum.chunk_every(4)

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [[back_button(hunt)]]}
  end

  defp picker_markup(hunt, :times) do
    rows =
      Store.time_options()
      |> Enum.map(fn time ->
        selected? = Enum.any?(hunt.times, &(Time.compare(&1, time) == :eq))
        label = if selected?, do: "✅ #{Views.format_time(time)}", else: Views.format_time(time)

        %ExGram.Model.InlineKeyboardButton{
          text: label,
          callback_data: "hunt:time:#{hunt.id}:#{Views.format_time(time)}"
        }
      end)
      |> Enum.chunk_every(4)

    %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: rows ++ [[back_button(hunt)]]}
  end

  defp picker_markup(hunt, :mode) do
    alert = if hunt.mode == :alert_only, do: "✅ 🔔 Alert only", else: "🔔 Alert only"
    auto = if hunt.mode == :auto_book, do: "✅ ⚡ Auto-book", else: "⚡ Auto-book"

    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{
            text: alert,
            callback_data: "hunt:mode:set:#{hunt.id}:alert_only"
          }
        ],
        [
          %ExGram.Model.InlineKeyboardButton{
            text: auto,
            callback_data: "hunt:mode:set:#{hunt.id}:auto_book"
          }
        ],
        [back_button(hunt)]
      ]
    }
  end

  defp picker_markup(hunt, :after) do
    stop = if hunt.after_match == :stop_on_first, do: "✅ 🛑 Stop on first", else: "🛑 Stop on first"
    cont = if hunt.after_match == :continue, do: "✅ 🔁 Continue", else: "🔁 Continue"

    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{
            text: stop,
            callback_data: "hunt:after:set:#{hunt.id}:stop_on_first"
          }
        ],
        [
          %ExGram.Model.InlineKeyboardButton{
            text: cont,
            callback_data: "hunt:after:set:#{hunt.id}:continue"
          }
        ],
        [back_button(hunt)]
      ]
    }
  end

  defp pace_markup do
    profile = Settings.poll_profile()
    human = if profile == :human_like, do: "✅ 🧍 Human-like", else: "🧍 Human-like"
    fast = if profile == :fast, do: "✅ ⚡ Fast", else: "⚡ Fast"

    %ExGram.Model.InlineKeyboardMarkup{
      inline_keyboard: [
        [
          %ExGram.Model.InlineKeyboardButton{
            text: human,
            callback_data: "hunt:pace:set:human_like"
          }
        ],
        [%ExGram.Model.InlineKeyboardButton{text: fast, callback_data: "hunt:pace:set:fast"}],
        [%ExGram.Model.InlineKeyboardButton{text: "Back", callback_data: "hunt:list"}]
      ]
    }
  end

  defp back_button(hunt),
    do: %ExGram.Model.InlineKeyboardButton{text: "← Back", callback_data: "hunt:show:#{hunt.id}"}

  defp edit(message, text, markup) do
    ExGram.edit_message_text(text,
      chat_id: message.chat.id,
      message_id: message.message_id,
      parse_mode: "Markdown",
      reply_markup: markup
    )
  end

  defp summary(hunt) do
    days = if hunt.weekdays == [], do: "📅 Any day", else: "📅 #{Enum.join(hunt.weekdays, ", ")}"

    times =
      if hunt.times == [],
        do: "🕒 Any time",
        else: "🕒 #{hunt.times |> Enum.map(&Views.format_time/1) |> Enum.join(", ")}"

    mode = if hunt.mode == :auto_book, do: "⚡ Auto-book", else: "🔔 Alert only"
    after_label = if hunt.after_match == :stop_on_first, do: "🛑 Stop on first", else: "🔁 Continue"
    "#{days} · #{times}\n#{mode} · #{after_label}"
  end

  defp pace_text, do: "🎛 Pace: #{pace_label(Settings.poll_profile())}"

  defp pace_button_text, do: "🎛 Pace: #{pace_label(Settings.poll_profile())}"

  defp pace_help_text do
    "🧍 *Human-like* is the default: 10–30 minute checks, occasional skips/long pauses, request delays, and full sleep overnight.\n\n⚡ *Fast* checks more often while still sleeping overnight. Use it only when you really care about a short window."
  end

  defp pace_label(:fast), do: "⚡ Fast"
  defp pace_label(_), do: "🧍 Human-like"

  defp status(%{active?: true}), do: "🟢"
  defp status(_), do: "⏸"

  defp blocked_label("active_booking_limit"), do: "active booking already exists"
  defp blocked_label(other), do: other

  defp escape(text) when is_binary(text), do: String.replace(text, "_", "\\_")
end
