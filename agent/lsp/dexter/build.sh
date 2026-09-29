#!/usr/bin/env bash
# Build an existing unmodified source checkout; never download or patch implicitly.
set -euo pipefail
source_dir="$(cd "${1:?Usage: build.sh /path/to/stock/dexter/source}" && pwd -P)"
revision=cd099f31b7701803292584887bb614628f721b0a
here="$(cd "$(dirname "$0")" && pwd -P)"
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision" || { echo 'Wrong upstream revision' >&2; exit 1; }
test -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" || { echo 'Source must be unmodified and have no untracked files' >&2; exit 1; }
mkdir -p "$here/vendor"
(cd "$source_dir" && go build -o "$here/vendor/dexter" ./cmd/)
python3 - "$here/vendor/dexter" "$revision" <<'PY'
import hashlib,json,sys
from pathlib import Path
binary = Path(sys.argv[1])
manifest = {'revision':sys.argv[2], 'binary':str(binary), 'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
(binary.parent / 'build.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(json.dumps(manifest, indent=2))
PY
