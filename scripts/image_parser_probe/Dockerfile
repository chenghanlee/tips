# Disposable image-parser probe for issue #244. Same Debian bookworm base as the release builder.
FROM hexpm/elixir:1.20.4-erlang-29.1-debian-bookworm-20260918-slim@sha256:29469d18548322a4612a7840aa542c05f359e4ff13f07dac9bb6336af0a97c58

# python3 runs the candidate parser; ffmpeg and webp build fixtures only.
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 python3-venv ffmpeg webp util-linux procps \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/parser/requirements.txt
RUN python3 -m venv /opt/parser/venv \
  && /opt/parser/venv/bin/pip install --no-cache-dir --only-binary=:all: --require-hashes -r /opt/parser/requirements.txt

WORKDIR /probe
