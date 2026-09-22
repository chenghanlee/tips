#!/usr/bin/env bash
# Upstream stdin framing fix: isaacphi/mcp-language-server#151.
# Drop this patch when an upstream release includes all bundled fixes.
set -euo pipefail

# Pin compiler and disable host C tooling for reproducible builds per OS/architecture.
export GOTOOLCHAIN=go1.26.3
export CGO_ENABLED=0

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tools_dir=${TIPS_ELIXIR_TOOLS:-"$script_dir/vendor"}
# Resolve relative overrides before changing into the temporary source tree.
[[ "$tools_dir" = /* ]] || tools_dir="$PWD/$tools_dir"
module_dir=$(go mod download -json github.com/isaacphi/mcp-language-server@v0.1.1 |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')
build_dir=$(mktemp -d)
staged_binary=""
trap 'rm -rf -- "$build_dir"; if [[ -n "$staged_binary" ]]; then rm -f -- "$staged_binary"; fi' EXIT
cp -R "$module_dir/." "$build_dir/"
chmod -R u+w "$build_dir"
cd "$build_dir"
patch -p1 --dry-run < "$script_dir/patches/mcp-bridge-tools-and-lifecycle.patch"
patch -p1 < "$script_dir/patches/mcp-bridge-tools-and-lifecycle.patch"
# Test the changed packages. Upstream integration tests require missing fixture
# workspaces/external servers; watcher timing tests can flake under build load (F7).
go vet ./...
go test . ./internal/lsp ./internal/tools ./internal/watcher
mkdir -p "$tools_dir/bin"
staged_binary=$(mktemp "$tools_dir/bin/mcp-language-server.XXXXXX")
go build -trimpath -buildvcs=false -o "$staged_binary" .
go version
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$staged_binary"
else
  shasum -a 256 "$staged_binary"
fi
chmod 755 "$staged_binary"
mv -f -- "$staged_binary" "$tools_dir/bin/mcp-language-server"
staged_binary=""
