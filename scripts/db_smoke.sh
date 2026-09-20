#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${DB_IMAGE:-ghcr.io/chenghanlee/tips-postgres:18.6-pgvector0.8.6-textsearch1.4.0}
container=""
cleanup() {
  result=$?
  if [[ -n "$container" ]]; then
    if (( result != 0 )); then docker logs "$container" >&2 || true; fi
    docker rm -fv "$container" >/dev/null || result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DOCKER_BUILDKIT=1 docker build --progress=plain -t "$image" "$repo_root/db"
container=$(docker run -d -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres "$image")
ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  # TCP excludes the entrypoint's temporary, socket-only initialization server.
  if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo 'PostgreSQL did not become ready within 60 seconds' >&2
  exit 1
fi
docker cp "$repo_root/db/smoke.sql" "$container:/tmp/smoke.sql"
docker exec "$container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/smoke.sql
