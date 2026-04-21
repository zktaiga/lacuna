<p align="center">
  <img src="assets/lacuna.png" width="160" alt="lacuna">
</p>

# lacuna

*a gap, watched.*

an elixir daemon that watches an amenity-booking backend and pings a telegram group the moment a slot opens. tap a button, take it. a standing watch can also auto-book matching openings when you explicitly opt in.

the http contract is isolated behind a small adapter. provider-specific bits live in env, not source.

## install

```sh
cp .env.example .env
mix deps.get
mix test
iex -S mix
```

fill `.env` before starting the daemon. use only accounts and booking systems you are authorized to automate. at minimum you need:

```sh
LACUNA_TELEGRAM_BOT_TOKEN=...
LACUNA_TELEGRAM_GROUP_CHAT_ID=...
LACUNA_OPERATOR_EMAIL=...
LACUNA_OPERATOR_PASSWORD=...
LACUNA_BACKEND_BASE_URL=https://example.invalid/
LACUNA_BACKEND_CLIENT_PACKAGE=com.example.app
LACUNA_BACKEND_CLIENT_BUILD=123
```

send `/help` or `/start` in the configured group. only that group chat is heard.

## docker

```sh
docker compose up -d --build
```

`prefs.toml` is bind-mounted. edit it on the host; callers re-read it on demand.

## commands

- `/free` — browse available slots: day → time → court → book.
- `/watch` — configure standing alerts: days, time window, expiry, cutoff, alert-only or auto-book.
- `/bookings` — list upcoming bookings and cancel with a confirmation step.
- `/help` — command list.

telegram inline buttons are used for actions. `/watch` has a close button so it does not stay sticky in the conversation.

## watch mode

watch mode is idle until enabled from `/watch`. the first successful poll records a silent baseline, so existing open slots do not spam the group. future newly-opened matching slots are announced.

watch filters:

- window: morning, afternoon, evening, or any time. evening starts at 18:00.
- days: any day or selected weekdays.
- until: 2h, 12h, 24h, or until manually turned off.
- stop: at slot start, T-30m, or T-1h. this suppresses slots that are already too close to starting.
- mode: alert only, or opt-in auto-book.

## session handling

sessions are cached in memory. login is followed by the dashboard activation call required by the backend, then a residential-unit lookup. authenticated requests mirror the mobile client context headers and recover from both HTTP 401 and app-envelope 401 by invalidating the cached session, logging in again, and retrying once.

## extending

three behaviours, swap them in `prefs.toml`:

- `Notifier` — reacts to bus events.
- `Booker` — books and cancels.
- `Matcher` — filters slots.

## drift

if the backend starts refusing requests, the contract may have drifted. paths and headers live in `lib/lacuna/backend/contract.ex`. keep provider-specific discovery notes and captures out of source control.

