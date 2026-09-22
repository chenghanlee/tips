#!/bin/sh
set -eu

# Bind the session to its assigned checkout even if the client changes cwd.
cd -- "${1:-$PWD}"
workspace=$(git rev-parse --show-toplevel)
cd -- "$workspace"

main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
tools_dir=${TIPS_ELIXIR_TOOLS:-"$main_checkout/.elixir-tools"}
exec "$tools_dir/bin/mcp-language-server" \
  --workspace "$PWD" \
  --lsp "$tools_dir/bin/expert" -- --stdio
