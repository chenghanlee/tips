#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
export TIPS_DB_PORT=5437 TIPS_APP_PORT=4300
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
[[ "$image_revision" == "$RELEASE_REVISION" ]]
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
"${compose[@]}" up -d db
wait_for_db() {
  for ((attempt = 0; attempt < 60; attempt++)); do
    if "${compose[@]}" exec -T db pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then return; fi
    sleep 1
  done
  echo 'Database did not become ready within 60 seconds' >&2
  return 1
}
wait_for_db
sql() { "${compose[@]}" exec -T db psql -X -U postgres -d "$1" -v ON_ERROR_STOP=1 -Atc "$2"; }
sql postgres 'CREATE DATABASE tips_release'
"${compose[@]}" run --rm --no-deps app bin/migrate
before=$(sql tips_release 'SELECT count(*) FROM schema_migrations')
[[ "$before" =~ ^[1-9][0-9]*$ ]]
"${compose[@]}" up -d --no-build app

request() {
  curl --silent --show-error --max-time 3 -D "$scratch/headers" -o "$scratch/body" \
    -w '%{http_code}' -H 'Host: tips.example' -H "X-Forwarded-Proto: $2" \
    "http://127.0.0.1:$TIPS_APP_PORT$1"
}
assert_health() {
  local code
  code=$(request /healthz "$3") || return 1
  [[ "$code" == "$1" && "$(cat "$scratch/body")" == "{\"status\":\"$2\"}" ]] || return 1
  grep -iq '^cache-control: no-store' "$scratch/headers"
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
[[ "$(request / http)" == 301 ]]
grep -iq $'^location: https://tips.example/\r$' "$scratch/headers"
echo 'PASS: migrated release, direct health probe, proxy probe, and HTTPS redirect'

"${compose[@]}" stop db
assert_health 503 error http
echo 'PASS: stopped DB returns exact 503 body within 3 seconds'
"${compose[@]}" start db
wait_for_db
"${compose[@]}" restart app
wait_for_app
assert_health 200 ok http
after=$(sql tips_release 'SELECT count(*) FROM schema_migrations')
[[ "$before" == "$after" ]]
printf 'PASS: restart preserves %s committed migrations\n' "$after"
