#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export TIPS_DB_PORT=5437 TIPS_APP_PORT=4300 PHX_HOST=tips.example
export SECRET_KEY_BASE=${SECRET_KEY_BASE:-$(openssl rand -base64 48)}
export RELEASE_REVISION=${RELEASE_REVISION:-$(git rev-parse HEAD)}
export TIPS_RELEASE_IMAGE=${TIPS_RELEASE_IMAGE:-tips-release-smoke:local}
compose=(docker compose -p tips-release-smoke)

case "${1:-}" in
  '') "${compose[@]}" build app ;;
  --skip-build) ;; # CI builds and loads this same image with the GHA layer cache.
  *) echo "Usage: $0 [--skip-build]" >&2; exit 2 ;;
esac
image_revision=$(docker image inspect "$TIPS_RELEASE_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
if [[ "$image_revision" != "$RELEASE_REVISION" ]]; then
  echo "Revision mismatch: expected $RELEASE_REVISION, got $image_revision" >&2
  exit 1
fi
printf 'Revision: %s\nImage ID: %s\n' "$image_revision" "$(docker image inspect "$TIPS_RELEASE_IMAGE" --format '{{.Id}}')"

scratch=$(mktemp -d)
cleanup() {
  result=$?
  if (( result != 0 )); then "${compose[@]}" logs --no-color >&2 || true; fi
  "${compose[@]}" down -v --remove-orphans || result=1
  rm -rf "$scratch"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This fixed project is disposable; never reset the shared development project.
"${compose[@]}" down -v --remove-orphans
"${compose[@]}" up -d --wait db
sql() { "${compose[@]}" exec -T db psql -X -U postgres -d "$1" -v ON_ERROR_STOP=1 -Atc "$2"; }
sql postgres 'CREATE DATABASE tips_release'
"${compose[@]}" run --rm --no-deps app bin/migrate
# The parser runs as the application runs it, on an image Pillow writes.
parsed=$("${compose[@]}" run --rm --no-deps app sh -c '
  python=/app/image_parser/bin/python
  $python -I -c "from PIL import Image; Image.new(\"RGB\", (2, 2)).save(\"/tmp/smoke.gif\")"
  timeout --signal=KILL 5 prlimit --as=1073741824 -- \
    $python -I /app/lib/tips-*/priv/image_parser/classify.py /tmp/smoke.gif')
[[ "$parsed" == *'"verdict": "accept", "format": "gif"'* ]] || { echo "Image parser failed: $parsed" >&2; exit 1; }
echo 'PASS: image parser classifies under its deadline and memory ceiling'
before=$(sql tips_release 'SELECT count(*) FROM schema_migrations')
[[ "$before" =~ ^[1-9][0-9]*$ ]] || { echo "Expected committed migrations, got: $before" >&2; exit 1; }
"${compose[@]}" up -d --no-build app

request() {
  curl --silent --show-error --max-time 3 -D "$scratch/headers" -o "$scratch/body" \
    -w '%{http_code}' -H "Host: ${3:-tips.example}" -H "X-Forwarded-Proto: $2" \
    "http://127.0.0.1:$TIPS_APP_PORT$1"
}
assert_health() {
  local code
  code=$(request /healthz "$3") || return 1
  if [[ "$code" != "$1" || "$(cat "$scratch/body")" != "{\"status\":\"$2\"}" ]]; then
    echo "Expected health HTTP $1/status $2, got HTTP $code: $(cat "$scratch/body")" >&2
    return 1
  fi
  grep -iq '^cache-control: no-store' "$scratch/headers" || {
    echo 'Health response is missing cache-control: no-store' >&2
    return 1
  }
}
wait_for_app() {
  for ((attempt = 0; attempt < 60; attempt++)); do
    if assert_health 200 ok http 2>/dev/null; then return; fi
    sleep 1
  done
  echo 'Application did not become healthy' >&2
  return 1
}
wait_for_app
assert_health 200 ok http
assert_health 200 ok https
[[ "$(request / http other.example)" == 301 ]] || { echo 'Expected HTTP / to redirect with 301' >&2; exit 1; }
grep -iq $'^location: https://tips.example/\r$' "$scratch/headers" || {
  echo 'Expected redirect to https://tips.example/' >&2
  cat "$scratch/headers" >&2
  exit 1
}
[[ "$(request / https)" == 200 ]] || { echo 'Expected HTTPS proxy / to return 200' >&2; exit 1; }
[[ "$(request / http localhost)" == 200 ]] || { echo 'Expected local HTTP / to return 200' >&2; exit 1; }
echo 'PASS: migrated release, direct health probe, proxy probe, and HTTPS redirect'

"${compose[@]}" stop db
assert_health 503 error http
echo 'PASS: stopped DB returns exact 503 body within 3 seconds'
# Remove anonymous volumes too, proving the named volume preserves committed state.
"${compose[@]}" rm -fsv db
"${compose[@]}" up -d --wait db
"${compose[@]}" restart app
wait_for_app
assert_health 200 ok http
after=$(sql tips_release 'SELECT count(*) FROM schema_migrations')
[[ "$before" == "$after" ]] || { echo "Migration count changed: $before -> $after" >&2; exit 1; }
printf 'PASS: restart preserves %s committed migrations\n' "$after"
