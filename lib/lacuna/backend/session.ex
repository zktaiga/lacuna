defmodule Lacuna.Backend.Session do
  @moduledoc """
  Holds the auth session state: cookie value, comm_id, user_id, and a
  registry of permitted URIs returned by login. Re-logs in on demand
  when the upstream rejects requests for being unauthenticated.

  `:idle` state means we haven't logged in yet (or we just got logged
  out). The first call to `current!/0` triggers a login if needed.
  """

  use GenServer
  require Logger

  alias Lacuna.Backend.{Contract, API}

  defstruct status: :idle,
            email: nil,
            password: nil,
            cookie: nil,
            session_id: nil,
            comm_id: nil,
            user_id: nil,
            ru_id: nil,
            uris: [],
            logged_in_at: nil,
            auth_failures: [],
            auth_paused_until: nil

  @type t :: %__MODULE__{}

  ## Public API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Set or update the credentials. Does not log in immediately — login
  happens lazily on first `current!/0`. Idempotent.
  """
  def configure(email, password), do: GenServer.call(__MODULE__, {:configure, email, password})

  @doc """
  Returns the current logged-in session, logging in on demand. Raises if
  no credentials have been configured.
  """
  @spec current!() :: t()
  def current!, do: GenServer.call(__MODULE__, :current!, 30_000)

  @doc "Force a re-login on the next request (e.g., after we see a 401-ish payload)."
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)

  @doc "Record an authentication failure and return whether callers should pause."
  def record_auth_failure, do: GenServer.call(__MODULE__, :record_auth_failure)

  @doc "Forget the persisted session cache, if configured."
  def clear_cache, do: GenServer.cast(__MODULE__, :clear_cache)

  @doc "Replace the cookie jar in-place. Called by the API client after every response."
  def update_cookie(cookie) when is_binary(cookie),
    do: GenServer.cast(__MODULE__, {:update_cookie, cookie})

  def update_cookie(_), do: :ok

  @doc """
  Headers the API client should add on every authenticated request.

  The cookie jar is sufficient for authentication, but the Android client
  also sends `Session-Id`, `comm_id`, and `Community-Code` from its okhttp
  interceptor. Some facility side effects appear to rely on that contextual
  header set even when the main API response succeeds, so mirror it exactly
  for authenticated calls.
  """
  @spec auth_headers(t()) :: [{String.t(), String.t()}]
  def auth_headers(%__MODULE__{} = s) do
    [
      {"Cookie", s.cookie || ""},
      {"Session-Id", s.session_id || s.cookie || ""},
      {"comm_id", s.comm_id || ""},
      {"Community-Code", ""}
    ] ++ Contract.static_headers()
  end

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:configure, email, password}, _from, state) do
    configured = %{state | email: email, password: password, status: :idle}
    {:reply, :ok, restore_cached_session(configured)}
  end

  def handle_call(:current!, _from, state) do
    case state.auth_paused_until do
      %DateTime{} = until ->
        if DateTime.compare(DateTime.utc_now(), until) == :lt do
          {:reply, {:error, {:auth_backoff, until}}, state}
        else
          current_unpaused(%{state | auth_paused_until: nil, auth_failures: []})
        end

      _ ->
        current_unpaused(state)
    end
  end

  def handle_call(:record_auth_failure, _from, state) do
    now = DateTime.utc_now()
    recent = [now | Enum.filter(state.auth_failures, &(DateTime.diff(now, &1, :second) < 120))]

    if length(recent) >= 3 do
      until = DateTime.add(now, 5 * 60, :second)

      Logger.warning(
        "Repeated authentication failures, pausing backend login until #{DateTime.to_iso8601(until)}"
      )

      {:reply, {:pause, until},
       %{state | auth_failures: recent, auth_paused_until: until, status: :idle}}
    else
      {:reply, :ok, %{state | auth_failures: recent}}
    end
  end

  defp current_unpaused(state) do
    case state do
      %{status: :ok} ->
        {:reply, state, state}

      %{email: nil} ->
        {:reply, {:error, :not_configured}, state}
        |> tap(fn _ -> Logger.warning("Backend.Session.current!/0 called before credentials") end)

      _ ->
        case do_login(state) do
          {:ok, fresh} ->
            {:reply, %{fresh | auth_failures: [], auth_paused_until: nil},
             %{fresh | auth_failures: [], auth_paused_until: nil}}

          {:error, reason} = err ->
            {:reply, err, %{state | status: :idle}} |> log_login_failure(reason)
        end
    end
  end

  @impl true
  def handle_cast(:invalidate, state), do: {:noreply, %{state | status: :idle}}

  def handle_cast(:clear_cache, state) do
    clear_cached_session()
    {:noreply, state}
  end

  def handle_cast({:update_cookie, cookie}, state) do
    new = %{state | cookie: cookie, session_id: cookie}
    persist_cached_session(new)
    {:noreply, new}
  end

  ## Internal

  defp do_login(state) do
    Logger.info("Logging in to booking backend as #{redact_email(state.email)}")

    case API.login(state.email, state.password) do
      {:ok, %{cookie: cookie, comm_id: comm_id, user_id: user_id, uris: uris} = login} ->
        {:ok,
         %{
           state
           | status: :ok,
             cookie: cookie,
             session_id: cookie,
             comm_id: comm_id,
             user_id: user_id,
             ru_id: Map.get(login, :ru_id),
             uris: uris,
             logged_in_at: DateTime.utc_now(),
             auth_failures: [],
             auth_paused_until: nil
         }
         |> tap(&persist_cached_session/1)}

      {:error, _} = err ->
        err
    end
  end

  defp restore_cached_session(state) do
    with path when is_binary(path) and path != "" <- cache_path(),
         {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         :ok <- cache_context_matches?(data),
         {:ok, logged_in_at} <- parse_cached_time(data["logged_in_at"]),
         true <- cache_fresh?(logged_in_at),
         cookie when is_binary(cookie) and cookie != "" <- data["cookie"] do
      Logger.info("Restored cached booking backend session")

      %{
        state
        | status: :ok,
          cookie: cookie,
          session_id: data["session_id"] || cookie,
          comm_id: data["comm_id"],
          user_id: data["user_id"],
          ru_id: data["ru_id"],
          uris: data["uris"] || [],
          logged_in_at: logged_in_at
      }
    else
      _ -> state
    end
  end

  defp persist_cached_session(%{status: :ok, cookie: cookie} = state)
       when is_binary(cookie) and cookie != "" do
    with path when is_binary(path) and path != "" <- cache_path(),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      data = %{
        cookie: state.cookie,
        session_id: state.session_id,
        comm_id: state.comm_id,
        user_id: state.user_id,
        ru_id: state.ru_id,
        uris: state.uris,
        logged_in_at: state.logged_in_at && DateTime.to_iso8601(state.logged_in_at),
        backend_base_url: Contract.base_url(),
        backend_client_package: Contract.client_package(),
        backend_client_build: Contract.client_build()
      }

      File.write!(path, Jason.encode!(data))
      File.chmod(path, 0o600)
    end
  rescue
    e -> Logger.debug("Session cache write failed: #{Exception.message(e)}")
  end

  defp persist_cached_session(_), do: :ok

  defp clear_cached_session do
    with path when is_binary(path) and path != "" <- cache_path() do
      File.rm(path)
    end
  rescue
    _ -> :ok
  end

  defp cache_path, do: Application.get_env(:lacuna, :session_cache_path)

  defp cache_context_matches?(data) do
    if data["backend_base_url"] == Contract.base_url() and
         data["backend_client_package"] == Contract.client_package() and
         data["backend_client_build"] == Contract.client_build() do
      :ok
    else
      :error
    end
  end

  defp parse_cached_time(nil), do: {:error, :missing_time}

  defp parse_cached_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      error -> error
    end
  end

  defp cache_fresh?(%DateTime{} = logged_in_at) do
    max_age = Application.get_env(:lacuna, :session_cache_max_age_minutes, 43_200)
    DateTime.diff(DateTime.utc_now(), logged_in_at, :minute) < max_age
  end

  defp log_login_failure(reply, reason) do
    Logger.error("Login failed: #{inspect(reason)}")
    reply
  end

  defp redact_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [<<first::binary-size(1), _::binary>>, domain] -> first <> "***@" <> domain
      [local, domain] when local != "" -> "***@" <> domain
      _ -> "configured account"
    end
  end

  defp redact_email(_), do: "configured account"
end
