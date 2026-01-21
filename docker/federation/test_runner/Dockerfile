# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.19.0-otp-28

FROM ${ELIXIR_IMAGE}

WORKDIR /app

ENV MIX_ENV=test

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./

RUN mix deps.get --only test
RUN mix deps.compile

COPY test test

CMD ["mix", "test", "--color"]

