defmodule Lacuna.Backend.Contract do
  @moduledoc """
  Single source of truth for the upstream HTTP contract.

  Operator-specific constants (`base_url`, `client_package`,
  `client_build`) live in env vars rather than in source so the
  codebase stays operator-agnostic. Default values resolve to a sentinel
  invalid host so misconfiguration fails loud instead of leaking
  requests somewhere unexpected.

  Endpoint paths and field names below describe the configured provider
  contract. Treat them as a starting position — if a call returns an
  unexpected shape, edit this module and re-run; nothing else should need
  to change.
  """

  @endpoints %{
    login: "auth/m_login/",
    logout: "auth/m_logout/",
    dashboard: "community_v2/m_get_dashboard_static_data/",
    facility_list: "facilities/m_get_facility_list",
    facility_bookings_info: "facilities/m_get_facility_bookings_info",
    facility_rates: "facilities/m_get_facility_rates_v2",
    my_bookings: "facilities/m_get_my_bookings_v3",
    make_booking: "facilities/m_member_make_booking",
    cancel_booking: "facilities/m_cancel_booking/",
    facility_charge_data: "facilities/m_get_facility_charge_data",
    member_ru_details: "runit/m_get_member_ru_and_gst_details/"
  }

  @default_base_url "https://example.invalid/"
  @default_client_package "com.example.app"
  @default_client_build "0"

  @spec base_url() :: String.t()
  def base_url, do: Application.get_env(:lacuna, :backend_base_url, @default_base_url)

  @spec client_build() :: String.t()
  def client_build, do: Application.get_env(:lacuna, :backend_client_build, @default_client_build)

  @spec client_package() :: String.t()
  def client_package,
    do: Application.get_env(:lacuna, :backend_client_package, @default_client_package)

  @doc """
  Static headers attached to every request. Session-bearing headers
  (`Cookie`, `Session-Id`, `comm_id`) are layered on top by
  `Lacuna.Backend.Session`.
  """
  def static_headers do
    build = client_build()

    [
      {"Client-Version", build},
      {"Client-Package", client_package()},
      {"X-ACCLIENT", "member_#{build}"},
      {"Connection", "Keep-Alive"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json,text/plain,*/*"},
      {"User-Agent", "okhttp/4.12.0"}
    ]
  end

  def endpoint(name) when is_map_key(@endpoints, name), do: Map.fetch!(@endpoints, name)
  def endpoints, do: @endpoints
end
