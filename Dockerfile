# syntax=docker/dockerfile:1
#
# Cloud image for autopoet — the SAME app the desktop runs, assembled headless
# for a vendored Fly machine (AUTOPOET_TARGET=cloud). NOT for the desktop build
# (that's burrito → a mac binary in Autopoet.app).
#
# The build context must contain ./autopoet and ./workbooks/nexus (the path dep),
# so `../workbooks/nexus` resolves from the app dir. Do NOT `docker build` this
# directory directly — use scripts/build-cloud-image.sh, which stages a PRUNED
# copy of both (nexus is 12GB; the prune drops _build/deps/.nexus/data/models).

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN=bookworm-20241016-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN} AS build

# native-dep tooling: exla downloads a prebuilt XLA, ortex a prebuilt ONNX
# runtime, tokenizers a precompiled NIF — all need curl/unzip/git at build.
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential git curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ortex is pinned to git main (elixir-nx/ortex) — a rustler NIF built from source, so we need cargo.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

ENV MIX_ENV=prod \
    AUTOPOET_TARGET=cloud \
    LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# the nexus path dep sits at the sibling location mix.exs expects (../workbooks/nexus); nexus in turn
# depends on ../tiny-lasers, so BOTH siblings must be present in the context.
WORKDIR /build
COPY workbooks/nexus /build/workbooks/nexus
COPY workbooks/tiny-lasers /build/workbooks/tiny-lasers

WORKDIR /build/autopoet
COPY autopoet/ ./
RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix compile
RUN mix release

# ── runtime ───────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN} AS app

RUN apt-get update -y && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    AUTOPOET_TARGET=cloud \
    AUTOPOET_PORT=8080 \
    WB_DATA=/data

WORKDIR /app
COPY --from=build /build/autopoet/_build/prod/rel/autopoet ./
RUN mkdir -p /data

EXPOSE 8080
# a health endpoint the machine config's check hits; the app serves it on AUTOPOET_PORT
CMD ["/app/bin/autopoet", "start"]
