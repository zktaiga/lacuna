defmodule Lacuna.Config do
  @moduledoc """
  Reads, validates, and exposes runtime preferences from `prefs.toml`.

  TOML lives at `:lacuna |> Application.get_env(:prefs_path)`. Re-read on
  demand by callers — there is no compiled cache, so editing `prefs.toml`
  takes effect on the next call to `load!/0`.
  """

  @type prefs :: %{
          poll: %{
            interval_seconds: pos_integer(),
            jitter_seconds: non_neg_integer(),
            interval_min_seconds: pos_integer(),
            interval_max_seconds: pos_integer(),
            lookahead_days: pos_integer(),
            backoff_seconds: pos_integer(),
            request_delay_min_ms: non_neg_integer(),
            request_delay_max_ms: non_neg_integer(),
            sleep: %{
              enabled: boolean(),
              start: String.t(),
              end: String.t(),
              wake_jitter_minutes: non_neg_integer()
            },
            behaviour: %{
              skip_probability: float(),
              long_pause_probability: float(),
              long_pause_min_minutes: pos_integer(),
              long_pause_max_minutes: pos_integer()
            }
          },
          hunt: %{
            time_options: [String.t()],
            default_times: [String.t()],
            max_active_hunts: pos_integer(),
            default_after_match: String.t()
          },
          match: %{
            category: String.t(),
            weekdays: [String.t()],
            start_hour: 0..23,
            end_hour: 0..23,
            court_ids: [String.t()]
          },
          booking: %{max_fee_aed: number()},
          plugins: %{
            notifiers: [module()],
            matchers: [module()],
            booker: module()
          }
        }

  @spec load!() :: prefs()
  def load! do
    path = Application.fetch_env!(:lacuna, :prefs_path)

    case Toml.decode_file(path) do
      {:ok, raw} -> validate!(raw)
      {:error, reason} -> raise "prefs.toml decode failed at #{path}: #{inspect(reason)}"
    end
  end

  defp validate!(raw) do
    %{
      poll: %{
        interval_seconds: get_in(raw, ["poll", "interval_seconds"]) || 300,
        jitter_seconds: get_in(raw, ["poll", "jitter_seconds"]) || 60,
        interval_min_seconds: get_in(raw, ["poll", "interval_min_seconds"]) || 600,
        interval_max_seconds: get_in(raw, ["poll", "interval_max_seconds"]) || 1800,
        lookahead_days: get_in(raw, ["poll", "lookahead_days"]) || 7,
        backoff_seconds: get_in(raw, ["poll", "backoff_seconds"]) || 1800,
        request_delay_min_ms: get_in(raw, ["poll", "request_delay_min_ms"]) || 1500,
        request_delay_max_ms: get_in(raw, ["poll", "request_delay_max_ms"]) || 6000,
        sleep: %{
          enabled: get_in(raw, ["poll", "sleep", "enabled"]) != false,
          start: get_in(raw, ["poll", "sleep", "start"]) || "23:30",
          end: get_in(raw, ["poll", "sleep", "end"]) || "09:00",
          wake_jitter_minutes: get_in(raw, ["poll", "sleep", "wake_jitter_minutes"]) || 30
        },
        behaviour: %{
          skip_probability: get_in(raw, ["poll", "behaviour", "skip_probability"]) || 0.08,
          long_pause_probability:
            get_in(raw, ["poll", "behaviour", "long_pause_probability"]) || 0.05,
          long_pause_min_minutes:
            get_in(raw, ["poll", "behaviour", "long_pause_min_minutes"]) || 60,
          long_pause_max_minutes:
            get_in(raw, ["poll", "behaviour", "long_pause_max_minutes"]) || 150
        }
      },
      hunt: %{
        time_options:
          get_in(raw, ["hunt", "time_options"]) ||
            ["06:00", "07:00", "08:00", "09:00", "18:00", "19:00", "20:00", "21:00"],
        default_times: get_in(raw, ["hunt", "default_times"]) || ["19:00", "20:00"],
        max_active_hunts: get_in(raw, ["hunt", "max_active_hunts"]) || 5,
        default_after_match: get_in(raw, ["hunt", "default_after_match"]) || "stop_on_first"
      },
      match: %{
        category: get_in(raw, ["match", "category"]) || "",
        weekdays: get_in(raw, ["match", "weekdays"]) || [],
        start_hour: get_in(raw, ["match", "start_hour"]) || 0,
        end_hour: get_in(raw, ["match", "end_hour"]) || 23,
        court_ids: get_in(raw, ["match", "court_ids"]) || []
      },
      booking: %{
        max_fee_aed: get_in(raw, ["booking", "max_fee_aed"]) || 0
      },
      plugins: %{
        notifiers: parse_modules(get_in(raw, ["plugins", "notifiers"]) || []),
        matchers: parse_modules(get_in(raw, ["plugins", "matchers"]) || []),
        booker: parse_module(get_in(raw, ["plugins", "booker"]))
      }
    }
  end

  defp parse_modules(list) when is_list(list), do: Enum.map(list, &parse_module/1)
  defp parse_module(nil), do: nil
  defp parse_module(name) when is_binary(name), do: String.to_atom(name)
end
