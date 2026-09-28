#!/usr/bin/env bash
# Build the pinned, unmodified Dexter source.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
revision=$(cat "$here/dexter.rev")
tools=${TIPS_ELIXIR_TOOLS:-"$here/vendor"}
mkdir -p "$tools"
tools=$(cd -- "$tools" && pwd)
source_dir="$tools/dexter-$revision"

if [[ ! -d "$source_dir/.git" ]]; then
  git clone https://github.com/remoteoss/dexter.git "$source_dir"
fi
if [[ -n $(git -C "$source_dir" status --porcelain) ]]; then
  echo "Refusing to overwrite modified Dexter sources: $source_dir" >&2
  exit 1
fi
git -C "$source_dir" checkout --detach "$revision"
mkdir -p "$tools/bin"
(
  cd -- "$source_dir"
  go build -mod=readonly -o "$tools/bin/dexter.new" ./cmd/
)
mv -f "$tools/bin/dexter.new" "$tools/bin/dexter"
printf 'Dexter %s installed in %s\n' "$revision" "$tools/bin"
