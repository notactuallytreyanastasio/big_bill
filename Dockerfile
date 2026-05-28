# === Builder stage ===
FROM hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20250520 AS builder

RUN apt-get update && \
    apt-get install -y build-essential git curl && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config ./config
RUN mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY assets ./assets

RUN mix assets.deploy
RUN mix compile
RUN mix release

# === Runner stage ===
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y libstdc++6 openssl libncurses5 locales && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/big_bill ./

EXPOSE 4000

CMD ["/bin/sh", "-c", "/app/bin/big_bill eval 'BigBill.Release.migrate()' && /app/bin/big_bill start"]
