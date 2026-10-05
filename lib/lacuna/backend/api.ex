defmodule Lacuna.Backend.API do
  @moduledoc """
  Stateless HTTP client. Wraps `Req` and the contract module.

  All calls are POST `application/x-www-form-urlencoded`. Response bodies
  are wrapped in the standard `ApiResponse` envelope from the upstream:

      %{"m_app_response" => %{
          "m_app_status_code" => 200,
          "m_app_status_msg" => "...",
          "m_response_data" => "<inner JSON string>"
        },
        "m_system_status_code" => 200}

  We unwrap to the inner data on success and surface a structured error
  otherwise. `Lacuna.Backend.Session` is the source of session/auth
  headers — we don't depend on it directly here so this module stays
  pure and easy to test.
  """

  require Logger
  alias Lacuna.Backend.Contract

  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Login + session activation.

  The upstream's session isn't usable immediately after `auth/m_login/`
  responds — the Android client follows up with a dashboard call which
  the server uses to "activate" the session and may set additional
  cookies. We replicate that here: a successful login returns the
  merged cookie jar from both responses.

  Returns `{:ok, %{cookie:, comm_id:, user_id:, uris:}}` on success.
  """
  @spec login(String.t(), String.t()) :: result()
  def login(email, password) do
    body = URI.encode_query(email: email, password: password, captcha: "captcha", comm_id: "")

    with {:ok, response, login_headers} <-
           request(:post, Contract.endpoint(:login), body, Contract.static_headers(),
             session: nil
           ),
         {:ok, login_data} <- parse_login_response(response, login_headers),
         {:ok, activated} <- activate_session(login_data),
         {:ok, with_ru} <- attach_ru_id(activated) do
      {:ok, with_ru}
    end
  end

  # POST community_v2/m_get_dashboard_static_data/ with the login cookies.
  # Merges any Set-Cookie returned into the existing jar.
  defp activate_session(%{cookie: cookie} = login_data) when is_binary(cookie) and cookie != "" do
    headers = [{"Cookie", cookie}] ++ Contract.static_headers()

    case request(:post, Contract.endpoint(:dashboard), "", headers, session: nil) do
      {:ok, _response, dashboard_headers} ->
        merged_cookie = merge_cookies(cookie, dashboard_headers)

        {:ok,
         login_data
         |> Map.put(:cookie, merged_cookie)
         |> put_newer_expiry(cookie_expires_at(dashboard_headers))}

      {:error, _} = err ->
        err
    end
  end

  defp activate_session(login_data), do: {:ok, login_data}

  defp attach_ru_id(%{cookie: cookie} = login_data) when is_binary(cookie) and cookie != "" do
    headers = [{"Cookie", cookie}] ++ Contract.static_headers()

    case request(:post, Contract.endpoint(:member_ru_details), "", headers, session: nil) do
      {:ok, response, ru_headers} ->
        merged_cookie = merge_cookies(cookie, ru_headers)

        ru_id =
          response
          |> unwrap_response()
          |> case do
            {:ok, data} -> find_ru_id(data)
            _ -> nil
          end

        {:ok,
         login_data
         |> Map.put(:cookie, merged_cookie)
         |> Map.put(:ru_id, ru_id)
         |> put_newer_expiry(cookie_expires_at(ru_headers))}

      {:error, _} ->
        {:ok, Map.put(login_data, :ru_id, nil)}
    end
  end

  defp attach_ru_id(login_data), do: {:ok, Map.put(login_data, :ru_id, nil)}

  # Merge a Cookie-jar string with new Set-Cookie headers; later values
  # for the same cookie name win.
  defp merge_cookies(existing, headers) do
    new_pairs =
      headers
      |> set_cookie_lines()
      |> Enum.map(fn line ->
        line |> String.split(";", parts: 2) |> List.first() |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))

    existing_pairs =
      (existing || "")
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    (existing_pairs ++ new_pairs)
    |> Enum.reverse()
    |> Enum.uniq_by(fn pair -> pair |> String.split("=", parts: 2) |> List.first() end)
    |> Enum.reverse()
    |> Enum.join("; ")
  end

  defp put_newer_expiry(data, nil), do: data

  defp put_newer_expiry(%{acsession_expires_at: nil} = data, expires_at),
    do: %{data | acsession_expires_at: expires_at}

  defp put_newer_expiry(%{acsession_expires_at: current} = data, expires_at) do
    if DateTime.compare(expires_at, current) == :gt,
      do: %{data | acsession_expires_at: expires_at},
      else: data
  end

  defp cookie_expires_at(headers) do
    headers
    |> set_cookie_lines()
    |> Enum.filter(&String.starts_with?(&1, "acsession="))
    |> Enum.find_value(&parse_cookie_expiry/1)
  end

  defp set_cookie_lines(headers) do
    headers
    |> Enum.flat_map(fn {k, v} ->
      if String.downcase(to_string(k)) == "set-cookie", do: List.wrap(v), else: []
    end)
  end

  defp parse_cookie_expiry(line) do
    attrs =
      line
      |> String.split(";")
      |> Enum.drop(1)
      |> Enum.map(&String.trim/1)

    case find_max_age(attrs) do
      seconds when is_integer(seconds) -> DateTime.add(DateTime.utc_now(), seconds, :second)
      nil -> attrs |> find_expires() |> parse_http_date()
    end
  end

  defp find_max_age(attrs) do
    Enum.find_value(attrs, fn attr ->
      case String.split(attr, "=", parts: 2) do
        [name, value] when name in ["Max-Age", "max-age"] -> parse_int(value)
        _ -> nil
      end
    end)
  end

  defp find_expires(attrs) do
    Enum.find_value(attrs, fn attr ->
      case String.split(attr, "=", parts: 2) do
        [name, value] when name in ["Expires", "expires"] -> value
        _ -> nil
      end
    end)
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_http_date(nil), do: nil

  defp parse_http_date(value) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/^\w{3},\s*(\d{2})-(\w{3})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$/,
             value
           ),
         month when is_integer(month) <- month_number(month),
         {:ok, date} <-
           Date.new(String.to_integer(year), month, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)) do
      DateTime.new!(date, time, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp month_number(month) do
    %{
      "Jan" => 1,
      "Feb" => 2,
      "Mar" => 3,
      "Apr" => 4,
      "May" => 5,
      "Jun" => 6,
      "Jul" => 7,
      "Aug" => 8,
      "Sep" => 9,
      "Oct" => 10,
      "Nov" => 11,
      "Dec" => 12
    }
    |> Map.get(month)
  end

  @doc "List all facilities for the user. Returns the inner `facilities[]` array."
  @spec list_facilities(map()) :: result()
  def list_facilities(session) do
    body = URI.encode_query(offset: "0", ru_id: "", categories: "[]")

    with {:ok, response, headers} <-
           request(:post, Contract.endpoint(:facility_list), body, session_headers(session),
             session: session
           ),
         _ <- update_session_cookies(session, headers),
         {:ok, inner} <- unwrap_response(response),
         %{"facilities" => %{"facilities" => list}} <- inner do
      {:ok, list}
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected_facility_list_shape, other}}
    end
  end

  @doc """
  Availability for one facility on one date. Returns the inner
  `facility_details` map as-is — caller computes free vs booked.
  """
  @spec facility_availability(map(), String.t(), Date.t()) :: result()
  def facility_availability(session, facility_id, %Date{} = date) do
    body =
      URI.encode_query(
        facility_id: facility_id,
        calendar_type: "date",
        date_info: format_date(date)
      )

    with {:ok, response, headers} <-
           request(
             :post,
             Contract.endpoint(:facility_bookings_info),
             body,
             session_headers(session),
             session: session
           ),
         _ <- update_session_cookies(session, headers),
         {:ok, inner} <- unwrap_response(response),
         %{"facility_details" => details} <- inner do
      {:ok, details}
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected_availability_shape, other}}
    end
  end

  @doc """
  Create a booking. Calling code passes the form fields because fixed-slot
  and free-time facilities use different booking-time parameters. We add
  the upstream defaults used by the Android client when omitted.
  """
  @spec make_booking(map(), map()) :: result()
  def make_booking(session, fields) when is_map(fields) do
    body =
      fields
      |> Map.put_new("booking_type", "0")
      |> Map.put_new("is_moderated", "false")
      |> URI.encode_query()

    with {:ok, response, headers} <-
           request(:post, Contract.endpoint(:make_booking), body, session_headers(session),
             session: session
           ),
         _ <- update_session_cookies(session, headers) do
      unwrap_response(response)
    end
  end

  @doc "Cancel a booking by id."
  @spec cancel_booking(map(), String.t()) :: result()
  def cancel_booking(session, booking_id) do
    body = URI.encode_query(booking_id: booking_id)

    with {:ok, response, headers} <-
           request(:post, Contract.endpoint(:cancel_booking), body, session_headers(session),
             session: session
           ),
         _ <- update_session_cookies(session, headers) do
      {:ok, response}
    end
  end

  @doc "List the user's existing bookings."
  @spec my_bookings(map()) :: result()
  def my_bookings(session) do
    body = URI.encode_query(offset_details: ~s({"offset": 0}), categories: "[]")

    with {:ok, response, headers} <-
           request(:post, Contract.endpoint(:my_bookings), body, session_headers(session),
             session: session
           ),
         _ <- update_session_cookies(session, headers) do
      unwrap_response(response)
    end
  end

  ## Internal

  defp session_headers(nil), do: Contract.static_headers()

  defp session_headers(%Lacuna.Backend.Session{} = session) do
    # Callers often hold a session struct for a whole workflow. If one request
    # refreshes the cached login, that struct is stale. Always prefer the
    # current GenServer state when available so later requests do not keep
    # presenting the expired cookie jar.
    case current_session() do
      %Lacuna.Backend.Session{} = fresh -> Lacuna.Backend.Session.auth_headers(fresh)
      _ -> Lacuna.Backend.Session.auth_headers(session)
    end
  end

  # Push new Set-Cookies back into the Session GenServer so the next
  # call sees them. Best-effort: we never crash a request because the
  # session refused the update.
  defp current_session do
    Lacuna.Backend.Session.current!()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp update_session_cookies(nil, _headers), do: :ok

  defp update_session_cookies(%{cookie: existing} = _session, headers) do
    new = merge_cookies(existing, headers)
    expires_at = cookie_expires_at(headers)

    Lacuna.Backend.Session.update_cookie(new, expires_at)
    :ok
  rescue
    _ -> :ok
  end

  defp request(method, path, body, headers, opts) do
    url = Contract.base_url() <> path

    req_headers =
      headers
      |> ensure_header({"Content-Type", "application/x-www-form-urlencoded"})
      |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end)

    case Req.request(
           method: method,
           url: url,
           headers: req_headers,
           body: body,
           connect_options: [timeout: 15_000],
           receive_timeout: 30_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: rh}}
      when status in 200..299 ->
        log_provider_request(method, path, status)
        decoded = decode(resp_body)

        if auth_rejected?(decoded) do
          retry_after_relogin(method, path, body, opts) || wrap(decoded, rh)
        else
          wrap(decoded, rh)
        end

      {:ok, %Req.Response{status: 401, body: resp_body}} ->
        log_provider_request(method, path, 401)

        retry_after_relogin(method, path, body, opts) ||
          {:error, {:http_status, 401, truncate(resp_body)}}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        log_provider_request(method, path, status)
        {:error, {:http_status, status, truncate(resp_body)}}

      {:error, reason} ->
        log_provider_request(method, path, {:transport, reason})
        {:error, {:transport, reason}}
    end
  end

  # Auth recovery is lease-aware: a rejected request first checks whether
  # another caller already refreshed the in-memory lease. Only the request
  # that still owns the current rejected cookie is allowed to force a relogin.
  # That avoids needless login storms, which matter because a fresh login can
  # invalidate the previous `acsession`.
  defp retry_after_relogin(method, path, body, opts) do
    with %Lacuna.Backend.Session{} = rejected <- Keyword.get(opts, :session),
         false <- Keyword.get(opts, :__retried, false) do
      case Lacuna.Backend.Session.handle_auth_rejection(rejected.cookie) do
        {:retry, %Lacuna.Backend.Session{} = fresh} ->
          Logger.info("Backend.API: 401 on #{path}, retrying with newer auth lease")
          retry_with_session(method, path, body, opts, fresh)

        :relogin ->
          case Lacuna.Backend.Session.current!() do
            %Lacuna.Backend.Session{} = fresh ->
              Logger.info("Backend.API: 401 on #{path}, re-logged in and retrying once")
              retry_with_session(method, path, body, opts, fresh)

            {:error, _} = err ->
              _ = record_auth_failure()
              err

            _ ->
              nil
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp retry_with_session(method, path, body, opts, fresh) do
    new_headers = Lacuna.Backend.Session.auth_headers(fresh)
    new_opts = Keyword.merge(opts, session: fresh, __retried: true)
    request(method, path, body, new_headers, new_opts)
  end

  defp log_provider_request(method, path, status) do
    level =
      if Application.get_env(:lacuna, :log_provider_requests, false), do: :info, else: :debug

    Logger.log(
      level,
      "Provider request #{String.upcase(to_string(method))} #{path} -> #{inspect(status)}"
    )
  end

  defp record_auth_failure do
    Lacuna.Backend.Session.record_auth_failure()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp wrap({:ok, decoded}, headers), do: {:ok, decoded, headers}

  defp auth_rejected?({:ok, %{"m_app_response" => %{"m_app_status_code" => code}}})
       when code in [401, "401"],
       do: true

  defp auth_rejected?({:ok, %{"m_system_status_code" => code}}) when code in [401, "401"],
    do: true

  defp auth_rejected?(_), do: false

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
    end
  end

  defp decode(other), do: {:ok, other}

  defp unwrap_response(%{
         "m_app_response" => %{"m_app_status_code" => code, "m_response_data" => nil}
       })
       when code in [200, "200"],
       do: {:ok, %{}}

  defp unwrap_response(%{
         "m_app_response" => %{"m_app_status_code" => code, "m_response_data" => data}
       })
       when code in [200, "200"] and is_map(data),
       do: {:ok, data}

  defp unwrap_response(%{
         "m_app_response" => %{"m_app_status_code" => code, "m_response_data" => data}
       })
       when code in [200, "200"] and is_binary(data) do
    case Jason.decode(data) do
      {:ok, inner} -> {:ok, inner}
      {:error, _} -> {:ok, data}
    end
  end

  defp unwrap_response(%{
         "m_app_response" => %{"m_app_status_code" => code, "m_app_status_msg" => msg}
       }),
       do: {:error, {:upstream, code, msg}}

  defp unwrap_response(other), do: {:error, {:envelope_unexpected, other}}

  defp parse_login_response(
         %{"m_app_response" => %{"m_app_status_code" => code, "m_response_data" => data}},
         headers
       )
       when code in [200, "200"] do
    cookie = build_cookie_header(headers)

    case Jason.decode(data) do
      {:ok, %{"comm_id" => comm_id, "user_id" => user_id} = parsed} ->
        {:ok,
         %{
           cookie: cookie,
           acsession_expires_at: cookie_expires_at(headers),
           comm_id: comm_id,
           user_id: user_id,
           uris: Map.get(parsed, "uris", [])
         }}

      {:ok, parsed} ->
        {:error, {:login_unexpected, parsed}}

      {:error, _} ->
        {:error, {:login_decode, data}}
    end
  end

  defp parse_login_response(envelope, _headers), do: {:error, {:login_envelope, envelope}}

  # The upstream sets multiple Set-Cookie values (acsession + PHPSESSID at
  # least). Authenticated calls need every name=value pair joined with "; ".
  defp build_cookie_header(headers) do
    headers
    |> Enum.flat_map(fn
      {k, v} ->
        if String.downcase(to_string(k)) == "set-cookie", do: List.wrap(v), else: []
    end)
    |> Enum.map(fn line ->
      line |> String.split(";", parts: 2) |> List.first() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  defp ensure_header(headers, {k, _v} = h) do
    if Enum.any?(headers, fn {hk, _} -> String.downcase(hk) == String.downcase(k) end),
      do: headers,
      else: [h | headers]
  end

  defp truncate(b) when is_binary(b), do: String.slice(b, 0, 200)
  defp truncate(other), do: inspect(other) |> String.slice(0, 200)

  defp find_ru_id(%{} = data) do
    cond do
      is_binary(data["ru_id"]) ->
        data["ru_id"]

      is_list(data["member_ru_details"]) ->
        data["member_ru_details"] |> Enum.find_value(&find_ru_id/1)

      is_list(data["r_units"]) ->
        data["r_units"] |> Enum.find_value(&find_ru_id/1)

      is_list(data["units"]) ->
        data["units"] |> Enum.find_value(&find_ru_id/1)

      true ->
        data |> Map.values() |> Enum.find_value(&find_ru_id/1)
    end
  end

  defp find_ru_id(list) when is_list(list), do: Enum.find_value(list, &find_ru_id/1)
  defp find_ru_id(_), do: nil

  # Upstream date format is dd/mm/yyyy.
  def format_date(%Date{day: d, month: m, year: y}),
    do: "#{pad2(d)}/#{pad2(m)}/#{y}"

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"
end
