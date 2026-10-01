#!/usr/bin/env bash
# Build one Dexter binary: the pinned upstream revision plus the cumulative local patch.
#
#   build.sh <dexter-git-repository> [--keep <dir>]
#
# The repository only has to contain the pinned commit; its checkout is not read.
# The patched source is prepared in a temporary copy (or in --keep <dir>, left in
# place for `go test ./...`), built into vendor/dexter, and described in
# vendor/build.json. The binary carries a local build id derived from the pin and
# the patch checksum; a daemon and a client with different ids refuse each other.
set -euo pipefail

upstream=c4b62b788bbe38f0af507a79f0d6de46dd812b51
here="$(cd "$(dirname "$0")" && pwd -P)"
patch_file="$here/patches/dexter-go.patch"
vendor="$here/vendor"
ldflags_var=github.com/remoteoss/dexter/internal/version.LocalBuildID

fail() { echo "build.sh: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
check_idle_binary() {
  local processes
  processes="$(ps -A -ww -o args=)" \
    || fail "cannot inspect processes; stop worktree daemons and retry where ps is available"
  if printf '%s\n' "$processes" | grep -F -- "$vendor/dexter daemon " >/dev/null; then
    fail "running daemon uses $vendor/dexter; stop it with its bound .dexter/dexter.sh stop, then rebuild and re-provision"
  fi
}

repository="${1:-}"
keep=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep="${2:?--keep needs a directory}"; shift 2 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
test -n "$repository" || fail "usage: build.sh <dexter-git-repository> [--keep <dir>]"
git -C "$repository" cat-file -e "$upstream^{commit}" 2>/dev/null || fail "$repository does not contain upstream commit $upstream"
test -s "$patch_file" || fail "missing $patch_file"
command -v go >/dev/null || fail "go is not installed"
check_idle_binary

patch_sha="$(sha256 "$patch_file")"
build_id="$(printf '%s\n%s\n' "$upstream" "$patch_sha" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"

if [ -n "$keep" ]; then
  mkdir -p "$keep"
  source_dir="$(cd "$keep" && pwd -P)"
  test -z "$(ls -A "$source_dir")" || fail "--keep directory is not empty: $source_dir"
else
  source_dir="$(mktemp -d "${TMPDIR:-/tmp}/dexter-go-build.XXXXXX")"
  trap 'rm -rf "$source_dir"' EXIT
fi

echo "Preparing $upstream + $(basename "$patch_file") ($patch_sha) in $source_dir" >&2
git -C "$repository" archive "$upstream" | tar -x -C "$source_dir"
git -C "$source_dir" init -q
git -C "$source_dir" apply --check "$patch_file"
git -C "$source_dir" apply "$patch_file"

(cd "$source_dir" && go build -trimpath -buildvcs=false -ldflags "-X $ldflags_var=$build_id" -o "$source_dir/dexter" ./cmd/)

version_output="$("$source_dir/dexter" version)"
printf '%s\n' "$version_output" | grep -qw -- "$build_id" \
  || fail "built binary does not report local build id $build_id; 'dexter version' printed: $version_output"

binary_sha="$(sha256 "$source_dir/dexter")"
# Recheck after compilation, immediately before replacing the shared executable.
check_idle_binary
mkdir -p "$vendor"
mv "$source_dir/dexter" "$vendor/dexter"
cat > "$vendor/build.json" <<JSON
{
  "upstream": "$upstream",
  "patch": {"file": "$(basename "$patch_file")", "sha256": "$patch_sha"},
  "local_build_id": "$build_id",
  "binary": {"path": "$vendor/dexter", "sha256": "$binary_sha"},
  "go": "$(go version)"
}
JSON
cat "$vendor/build.json"
