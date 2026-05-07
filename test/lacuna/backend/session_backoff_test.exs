defmodule Lacuna.Backend.SessionBackoffTest do
  use ExUnit.Case, async: false

  alias Lacuna.Backend.Session

  setup do
    start_supervised!(Session)
    :ok
  end

  test "repeated auth failures pause new logins" do
    assert :ok = Session.record_auth_failure()
    assert :ok = Session.record_auth_failure()
    assert {:pause, %DateTime{} = until} = Session.record_auth_failure()

    assert {:error, {:auth_backoff, ^until}} = Session.current!()
  end
end
