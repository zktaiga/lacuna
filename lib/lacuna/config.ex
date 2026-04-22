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
            lookahead_days: pos_integer(),
            backoff_seconds: pos_integer()
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
        lookahead_days: get_in(raw, ["poll", "lookahead_days"]) || 7,
        backoff_seconds: get_in(raw, ["poll", "backoff_seconds"]) || 600
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
