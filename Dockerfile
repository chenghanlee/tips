# Pinned application build and runtime images. See docs/development/toolchain.md.
FROM hexpm/elixir:1.20.4-erlang-29.1-debian-bookworm-20260918-slim@sha256:29469d18548322a4612a7840aa542c05f359e4ff13f07dac9bb6336af0a97c58 AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex 2.5.1 --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV --check-locked
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM debian:bookworm-20260918-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
    python3 python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Pillow for the image parser (Tips.Content.Media.ImageParser). timeout and prlimit
# come with the base image.
COPY priv/image_parser/requirements.txt /tmp/image_parser_requirements.txt
RUN python3 -m venv /app/image_parser \
  && /app/image_parser/bin/pip install --no-cache-dir --require-hashes --no-deps \
    -r /tmp/image_parser_requirements.txt \
  && rm /tmp/image_parser_requirements.txt

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/tips ./

ARG RELEASE_REVISION
LABEL org.opencontainers.image.revision=$RELEASE_REVISION

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
