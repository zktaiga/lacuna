import Config
import Dotenvy

is_test? = config_env() == :test

# Merge .env (if present) with the OS environment.
source!([Path.expand("../.env", __DIR__), System.get_env()])

bot_token =
  case {env!("LACUNA_TELEGRAM_BOT_TOKEN", :string, nil), is_test?} do
    {nil, true} -> "test-token"
    {"", true} -> "test-token"
    {nil, false} -> raise "LACUNA_TELEGRAM_BOT_TOKEN is not set (put it in .env)"
    {"", false} -> raise "LACUNA_TELEGRAM_BOT_TOKEN is empty"
    {value, _} -> value
  end

group_chat_id =
  case {env!("LACUNA_TELEGRAM_GROUP_CHAT_ID", :string, nil), is_test?} do
    {v, true} when v in [nil, ""] -> 0
    {nil, false} -> raise "LACUNA_TELEGRAM_GROUP_CHAT_ID is not set"
    {"", false} -> raise "LACUNA_TELEGRAM_GROUP_CHAT_ID is empty"
    {value, _} -> String.to_integer(value)
  end

config :ex_gram, token: bot_token

config :lacuna,
  telegram_bot_token: bot_token,
  telegram_group_chat_id: group_chat_id,
  operator_email: env!("LACUNA_OPERATOR_EMAIL", :string, nil),
  operator_password: env!("LACUNA_OPERATOR_PASSWORD", :string, nil),
  backend_base_url: env!("LACUNA_BACKEND_BASE_URL", :string, "https://example.invalid/"),
  backend_client_package: env!("LACUNA_BACKEND_CLIENT_PACKAGE", :string, "com.example.app"),
  backend_client_build: env!("LACUNA_BACKEND_CLIENT_BUILD", :string, "0")
