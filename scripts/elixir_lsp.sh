#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
exec .elixir-tools/bin/mcp-language-server \
  --workspace "$PWD" \
  --lsp "$PWD/.elixir-tools/bin/expert" -- --stdio
