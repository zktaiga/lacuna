defmodule Lacuna.Telegram.CallbacksTest do
  use ExUnit.Case, async: false

  alias Lacuna.Hunts.Store
  alias Lacuna.Telegram.Callbacks

  setup do
    store_path =
      Path.join(System.tmp_dir!(), "lacuna-hunts-#{System.unique_integer([:positive])}.json")

    Application.put_env(:lacuna, :hunt_store_path, store_path)

    start_supervised!({Store, []})

    {:ok, hunt} = Store.create_default()

    on_exit(fn -> File.rm(store_path) end)

    %{hunt: hunt}
  end

  test "after-match set callbacks are routed before generic after picker", %{hunt: hunt} do
    handle("hunt:after:set:#{hunt.id}:continue")

    assert Store.get(hunt.id).after_match == :continue
  end

  test "mode set callbacks are routed before generic mode picker", %{hunt: hunt} do
    handle("hunt:mode:set:#{hunt.id}:auto_book")

    assert Store.get(hunt.id).mode == :auto_book
  end

  test "/free navigation callback data is stateless" do
    assert Lacuna.Telegram.Free.callback_data("root") == "f:root"
    assert Lacuna.Telegram.Free.callback_data("d:2026-06-04") == "f:d:2026-06-04"
    assert Lacuna.Telegram.Free.callback_data("t:2026-06-04:15-00") == "f:t:2026-06-04:15-00"
  end

  defp handle(data) do
    cq = %ExGram.Model.CallbackQuery{
      id: "test-callback",
      data: data,
      message: %ExGram.Model.Message{chat: %ExGram.Model.Chat{id: 0}, message_id: 0}
    }

    Callbacks.handle(cq, %{})
  end
end
