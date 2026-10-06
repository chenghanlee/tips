#!/usr/bin/env bash
# Disposable image-parser probe for issue #244. Builds the probe image and runs
# probe.exs in it. Output goes to tmp/image-parser-probe/<run-id>/.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

# Record the launch revision and cleanliness before building or running anything.
revision=$(git rev-parse HEAD)
tracked_changes=$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')
run_id=$(date -u +%Y%m%dT%H%M%SZ)
out="tmp/image-parser-probe/$run_id"
mkdir -p "$out"
echo "revision $revision; tracked changes $tracked_changes; run $run_id"

platform=${PROBE_PLATFORM:-}
image="tips-image-parser-probe:local${platform:+-${platform//\//-}}"
docker build -q ${platform:+--platform "$platform"} -t "$image" scripts/image_parser_probe >/dev/null

# The OTP JIT needs single-mapped code memory under qemu emulation.
docker run --rm ${platform:+--platform "$platform" -e "ELIXIR_ERL_OPTIONS=+JMsingle true"} \
  -e PROBE_REVISION="$revision" -e PROBE_TRACKED_CHANGES="$tracked_changes" \
  -v "$root/scripts/image_parser_probe:/probe/src:ro" -v "$root/$out:/probe/out" \
  "$image" elixir /probe/src/probe.exs /probe/out
