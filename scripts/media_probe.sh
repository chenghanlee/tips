#!/usr/bin/env bash
# Disposable media provider/parser probe for issue #61.
# See docs/development/media-provider-probe.md.
#
#   bash scripts/media_probe.sh parser
#   TIPS_REAL_PROVIDERS=1 bash scripts/media_probe.sh stream|r2|cleanup
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-}"
out="tmp/media-probe"
mkdir -p "$out"

case "$mode" in
  parser)
    exec elixir scripts/media_probe/parser.exs "$out/parser"
    ;;
  stream|r2|cleanup|signing-key)
    if [[ "${TIPS_REAL_PROVIDERS:-}" != "1" ]]; then
      echo "refused: $mode calls real providers; set TIPS_REAL_PROVIDERS=1 to opt in" >&2
      exit 2
    fi
    exec elixir scripts/media_probe/provider.exs "$mode" "$out"
    ;;
  *)
    echo "usage: bash scripts/media_probe.sh parser|stream|r2|cleanup|signing-key" >&2
    exit 64
    ;;
esac
