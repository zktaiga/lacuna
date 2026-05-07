defmodule Lacuna.Watcher.Poller do
  @moduledoc """
  The heart. A GenServer that ticks every `poll.interval_seconds`
  (jittered), fetches availability for every watched court × every day
  in the lookahead window, computes open slots, diffs against the
  previous snapshot, and publishes events on the `:lacuna` PubSub group
  via `Lacuna.Bus`.

  States:
    * `:idle`   — not polling. `/start` flips to `:running`.
    * `:running` — ticking on schedule.
    * `:paused`  — like idle but remembers we were running. `/resume`
                   resumes immediately.

  The poller is resilient: a thrown exception in the fetch path is
  caught, logged, published as `:poll_failed`, and the next tick is
  rescheduled with the configured backoff.
  """

  use GenServer
  require Logger

  alias Lacuna.{Bus, Config, Watcher.State, Watcher.Differ, Watch}
  alias Lacuna.Backend.{API, Availability, Courts, Session}

  defstruct status: :idle,
            timer: nil,
            snapshot: %{},
            bootstrapped?: false,
            last_tick_at: nil,
            last_error: nil,
            quiet_until: nil

  ## Public

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)
  def force_tick, do: GenServer.cast(__MODULE__, :tick_now)

  @doc "Mute notifications until the given DateTime (UTC) is reached."
  def quiet_until(%DateTime{} = until), do: GenServer.cast(__MODULE__, {:quiet_until, until})

  ## GenServer

  @impl true
  def init(_opts) do
    # Schedule a deferred check; real ticking only starts when /watch enables.
    send(self(), :watch_changed)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, s) do
    {:reply,
     %{
       status: s.status,
       last_tick_at: s.last_tick_at,
       last_error: s.last_error,
       open_slot_count: map_size(s.snapshot),
       quiet_until: s.quiet_until
     }, s}
  end

  @impl true
  def handle_cast(:tick_now, s), do: {:noreply, schedule_tick(s, 0)}
  def handle_cast({:quiet_until, until}, s), do: {:noreply, %{s | quiet_until: until}}

  @impl true
  def handle_info(:tick, s) do
    if Watch.Config.active?() do
      case run_tick(s) do
        {:ok, new_state} ->
          {:noreply, schedule_tick(%{new_state | status: :running}, nil)}

        {:error, reason, new_state} ->
          Bus.publish({:poll_failed, reason})
          {:noreply, schedule_tick(%{new_state | status: :running}, backoff_ms())}
      end
    else
      cancel(s.timer)
      {:noreply, %{s | status: :idle, timer: nil, snapshot: %{}, bootstrapped?: false}}
    end
  end

  def handle_info(:watch_changed, s) do
    cond do
      Watch.Config.active?() and s.status != :running ->
        Logger.info("Watch enabled — scheduling immediate poll tick")
        {:noreply, schedule_tick(%{s | status: :running}, 0)}

      not Watch.Config.active?() and s.status == :running ->
        Logger.info("Watch disabled — pausing poller")
        cancel(s.timer)
        {:noreply, %{s | status: :idle, timer: nil, snapshot: %{}, bootstrapped?: false}}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(_other, s), do: {:noreply, s}

  ## Tick implementation

  defp run_tick(%{snapshot: prev, bootstrapped?: bootstrapped} = s) do
    prefs = Config.load!()

    with {:ok, courts} <- ensure_courts(),
         {:ok, slots} <- fetch_all_slots(courts, prefs) do
      now = slots |> Enum.filter(&Watch.Config.matches?/1) |> State.from_slots()

      cond do
        not bootstrapped ->
          # First successful tick: capture baseline silently. We never
          # want to alert on slots that were already open before the
          # bot started watching.
          Logger.info("Watcher bootstrap: #{map_size(now)} open slots recorded as baseline")

          {:ok,
           %{
             s
             | snapshot: now,
               bootstrapped?: true,
               last_tick_at: DateTime.utc_now(),
               last_error: nil
           }}

        true ->
          %{opened: opened, closed: closed} = Differ.diff(prev, now)

          if not muted?(s), do: publish_events(opened, closed, prefs)

          {:ok, %{s | snapshot: now, last_tick_at: DateTime.utc_now(), last_error: nil}}
      end
    else
      {:error, reason} ->
        Logger.error("Poll tick failed: #{inspect(reason)}")
        {:error, reason, %{s | last_error: reason, last_tick_at: DateTime.utc_now()}}
    end
  rescue
    e ->
      Logger.error("Poll tick raised: #{Exception.message(e)}")
      {:error, e, %{s | last_error: e, last_tick_at: DateTime.utc_now()}}
  end

  defp ensure_courts do
    case Courts.load() do
      {:ok, courts} ->
        {:ok, courts}

      {:error, :not_yet_discovered} ->
        Logger.info("courts.json missing — discovering once via Backend.API")
        discover_courts()
    end
  end

  defp discover_courts do
    prefs = Config.load!()

    with session <- Session.current!(),
         {:ok, list} <- API.list_facilities(session) do
      filtered = Courts.filter_by_category(list, prefs.match.category)

      catalog =
        Enum.map(filtered, fn f ->
          %{
            id: Map.get(f, "facility_id"),
            name: Map.get(f, "facility_name"),
            short_name: Map.get(f, "facility_name")
          }
        end)

      :ok = Courts.save(catalog)

      Logger.info(
        "Discovered #{length(catalog)} courts: #{inspect(Enum.map(catalog, & &1.name))}"
      )

      {:ok, catalog}
    else
      {:error, reason} -> {:error, {:discover_failed, reason}}
    end
  end

  @doc false
  def planned_dates(%Date{} = today, lookahead_days) do
    for d <- 0..(lookahead_days - 1),
        date = Date.add(today, d),
        Watch.Config.date_matches_weekday?(date),
        do: date
  end

  defp fetch_all_slots(courts, prefs) do
    days = planned_dates(Lacuna.Clock.local_today(), prefs.poll.lookahead_days)

    pairs = for c <- courts, d <- days, do: {c, d}

    Enum.reduce_while(pairs, {:ok, []}, fn {court, date}, {:ok, acc} ->
      maybe_sleep_between_requests(prefs)

      # Fetch the current session for each request. A previous request may
      # have refreshed the cached login after a 401, and reusing the stale
      # struct for the rest of the poll would otherwise trigger one re-login
      # per court/date pair.
      session = Session.current!()

      case API.facility_availability(session, court.id, date) do
        {:ok, details} ->
          # facility_availability returns the facility_details map; ensure facility_id present
          details = Map.put_new(details, "facility_id", court.id)
          slots = Availability.open_slots(details, date)
          {:cont, {:ok, acc ++ slots}}

        {:error, reason} ->
          {:halt, {:error, {court.id, date, reason}}}
      end
    end)
  end

  defp maybe_sleep_between_requests(%{
         poll: %{request_delay_min_ms: min, request_delay_max_ms: max}
       }) do
    delay = jittered_request_delay(min, max)
    if delay > 0, do: Process.sleep(delay)
  end

  defp jittered_request_delay(min, max) when min <= 0 and max <= 0, do: 0
  defp jittered_request_delay(min, max) when max <= min, do: max(min, 0)
  defp jittered_request_delay(min, max), do: min + :rand.uniform(max - min + 1) - 1

  defp publish_events(opened, closed, _prefs) do
    Enum.each(opened, fn slot -> Bus.publish({:slot_opened, slot}) end)

    Enum.each(closed, fn slot -> Bus.publish({:slot_closed, slot}) end)
  end

  defp muted?(%{quiet_until: nil}), do: false

  defp muted?(%{quiet_until: until}),
    do: DateTime.compare(DateTime.utc_now(), until) == :lt

  ## Scheduling

  defp schedule_tick(s, ms_override) do
    cancel(s.timer)
    delay = ms_override || jittered_delay(Config.load!())
    timer = Process.send_after(self(), :tick, delay)
    %{s | timer: timer}
  end

  defp jittered_delay(prefs) do
    base = prefs.poll.interval_seconds * 1_000
    jitter = prefs.poll.jitter_seconds * 1_000
    base + :rand.uniform(jitter * 2 + 1) - jitter - 1
  end

  defp backoff_ms do
    prefs = Config.load!()
    prefs.poll.backoff_seconds * 1_000
  end

  defp cancel(nil), do: :ok
  defp cancel(t) when is_reference(t), do: Process.cancel_timer(t)
end
