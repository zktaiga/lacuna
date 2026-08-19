defmodule Lacuna.Telegram.BookingReceiptTest do
  use ExUnit.Case, async: false

  alias Lacuna.Telegram.BookingReceipt

  defmodule TelegramStub do
    def send_message(chat_id, text, opts) do
      send(Process.whereis(:booking_receipt_test), {:sent, chat_id, text, opts})

      case Process.get(:send_result) do
        nil -> {:ok, %{message_id: 99}}
        result -> result
      end
    end

    def delete_message(chat_id, message_id) do
      send(Process.whereis(:booking_receipt_test), {:deleted, chat_id, message_id})
      {:ok, true}
    end
  end

  setup do
    Process.register(self(), :booking_receipt_test)

    on_exit(fn ->
      if Process.whereis(:booking_receipt_test), do: Process.unregister(:booking_receipt_test)
    end)
  end

  test "posts a new confirmation before consuming the interactive menu" do
    assert :ok = BookingReceipt.publish(-100, 42, "✅ Booked", TelegramStub)

    assert_receive {:sent, -100, "✅ Booked", [parse_mode: "Markdown"]}
    assert_receive {:deleted, -100, 42}
  end

  test "keeps the interactive menu available as a fallback when sending fails" do
    Process.put(:send_result, {:error, :telegram_unavailable})

    assert {:error, :telegram_unavailable} =
             BookingReceipt.publish(-100, 42, "✅ Booked", TelegramStub)

    assert_receive {:sent, -100, "✅ Booked", [parse_mode: "Markdown"]}
    refute_receive {:deleted, -100, 42}
  end
end
