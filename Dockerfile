# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.19.0-otp-28
ARG RUNNER_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS builder

ENV MIX_ENV=prod

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile
RUN mix assets.deploy
RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libncurses6 \
    libstdc++6 \
    openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV LANG=C.UTF-8
ENV PHX_SERVER=true
ENV EGREGOROS_UPLOADS_DIR=/data/uploads

COPY --from=builder /app/_build/prod/rel/egregoros ./

RUN useradd --create-home --shell /bin/bash egregoros && \
    mkdir -p /data/uploads && \
    chown -R egregoros:egregoros /app /data

USER egregoros

EXPOSE 4000

CMD ["bin/egregoros", "start"]

