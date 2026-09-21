#!/bin/sh
set -eu

main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
tools_dir=${TIPS_ELIXIR_TOOLS:-"$main_checkout/.elixir-tools"}
exec "$tools_dir/bin/mcp-language-server" \
  --workspace "$PWD" \
  --lsp "$tools_dir/bin/expert" -- --stdio
