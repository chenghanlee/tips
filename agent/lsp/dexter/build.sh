#!/usr/bin/env bash
# Build the pinned source plus the reviewed local arity patch in a disposable copy.
set -euo pipefail
source_dir="$(cd "${1:?Usage: build.sh /path/to/stock/dexter/source}" && pwd -P)"
revision=cd099f31b7701803292584887bb614628f721b0a
here="$(cd "$(dirname "$0")" && pwd -P)"
patch_file="$here/patches/function-arity.patch"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision" || { echo 'Wrong upstream revision' >&2; exit 1; }
test -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" || { echo 'Source must be unmodified and have no untracked files' >&2; exit 1; }
test -s "$patch_file" || { echo 'Missing local function-arity patch' >&2; exit 1; }
printf '%s\n' 'Active worktrees: stop their daemons with the existing bound command BEFORE replacing this build; refresh bound checksums and start them after the build.' >&2
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/dexter-arity-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
git -C "$source_dir" archive "$revision" | tar -x -C "$build_dir"
git -C "$build_dir" init -q
git -C "$build_dir" apply --check "$patch_file"
git -C "$build_dir" apply "$patch_file"
mkdir -p "$here/vendor"
(cd "$build_dir" && go build -trimpath -buildvcs=false -o "$here/vendor/dexter" ./cmd/)
python3 - "$here/vendor/dexter" "$revision" "$patch_file" <<'PY'
import hashlib,json,sys
from pathlib import Path
binary = Path(sys.argv[1])
patch = Path(sys.argv[3])
manifest = {
    'revision':sys.argv[2], 'binary':str(binary),
    'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'local_patch':{'file':patch.name, 'sha256':hashlib.sha256(patch.read_bytes()).hexdigest()},
}
(binary.parent / 'build.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest, indent=2))
PY
