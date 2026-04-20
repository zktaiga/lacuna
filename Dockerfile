# syntax=docker/dockerfile:1.7

# ---- Builder ----
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4
ARG DEBIAN_VERSION=bookworm-20260421-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY prefs.toml ./prefs.toml

RUN mix compile && mix release lacuna

# ---- Runtime ----
FROM debian:${DEBIAN_VERSION} AS runtime

ENV LANG=C.UTF-8 \
    HOME=/app

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libstdc++6 libssl3 libncurses6 locales tzdata ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR /app

# Non-root user for the daemon
RUN groupadd -r lacuna && useradd -r -g lacuna -d /app -s /sbin/nologin lacuna

COPY --from=builder --chown=lacuna:lacuna /app/_build/prod/rel/lacuna ./
COPY --chown=lacuna:lacuna prefs.toml ./prefs.toml

# courts.json + recon HARs are produced at runtime — make a writable dir
RUN install -d -o lacuna -g lacuna /app/data
VOLUME ["/app/data"]

# Mounted at runtime: /app/.env (read-only)
USER lacuna

ENV LACUNA_BACKEND_BASE_URL="" \
    LACUNA_BACKEND_CLIENT_PACKAGE="" \
    LACUNA_BACKEND_CLIENT_BUILD=""

ENTRYPOINT ["/app/bin/lacuna"]
CMD ["start"]
