#!/usr/bin/env bash
# Local Expert 0.1.10 references contract and parallel-worktree fixes. No upstream submission.
set -euo pipefail

revision=1a74fe98762fde17409434fdfc64c4dae1e67537
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "$script_dir/../.." && pwd)
tools_dir=${TIPS_ELIXIR_TOOLS:-"$repo_dir/.elixir-tools"}
[[ "$tools_dir" = /* ]] || tools_dir="$PWD/$tools_dir"
# An optional local clone still has to supply the exact pinned commit.
source_repo=${TIPS_EXPERT_REPOSITORY:-https://github.com/expert-lsp/expert.git}
build_dir=$(mktemp -d)
staged_link=""
trap 'rm -rf -- "$build_dir"; if [[ -n "$staged_link" ]]; then rm -f -- "$staged_link"; fi' EXIT

for command in git python3 unbuffer mix; do
  command -v "$command" >/dev/null || { echo "Missing build prerequisite: $command" >&2; exit 1; }
done
hash=$(python3 - "$script_dir/patches/expert-reference-results.patch" "$script_dir/patches/expert-worktree-isolation.patch" "$script_dir/patches/expert-generated-data.patch" <<'PY'
import hashlib, sys
digest = hashlib.sha256()
for path in sys.argv[1:]:
    data = open(path, 'rb').read()
    digest.update(len(data).to_bytes(8, 'big'))
    digest.update(data)
print(digest.hexdigest())
PY
)
version="0.1.10-tips.${hash:0:16}"
release_dir="$tools_dir/releases/expert-$version"
if [[ -e "$release_dir" ]]; then
  echo "Release already exists: $release_dir (remove it explicitly to rebuild)" >&2
  exit 1
fi

git init -q "$build_dir/repository"
git -C "$build_dir/repository" fetch -q --depth=1 "$source_repo" "$revision"
[[ $(git -C "$build_dir/repository" rev-parse FETCH_HEAD) = "$revision" ]]
mkdir "$build_dir/source"
# Benchmarks use LFS assets; the targeted test suites do not need them.
git -C "$build_dir/repository" -c filter.lfs.process= -c filter.lfs.smudge=cat -c filter.lfs.required=false archive FETCH_HEAD |
  tar -x -C "$build_dir/source"
cd "$build_dir/source"
patch -p1 --dry-run < "$script_dir/patches/expert-reference-results.patch"
patch -p1 < "$script_dir/patches/expert-reference-results.patch"
patch -p1 --dry-run < "$script_dir/patches/expert-worktree-isolation.patch"
patch -p1 < "$script_dir/patches/expert-worktree-isolation.patch"
patch -p1 --dry-run < "$script_dir/patches/expert-generated-data.patch"
patch -p1 < "$script_dir/patches/expert-generated-data.patch"
printf '%s\n' "$version" > version.txt

for app in forge engine expert; do
  (
    cd "apps/$app"
    export MIX_ENV=test
    export ERL_FLAGS="${ERL_FLAGS:-} -setcookie tips_contract_test -start_epmd false -epmd_module Elixir.Forge.EPMD"
    unbuffer mix deps.get
    # Pinned upstream emits existing type warnings on Elixir 1.20; tests below
    # still reject new warnings in the contract tests.
    unbuffer mix compile
    if [[ "$app" = forge ]]; then
      changed=(lib/forge/project.ex test/forge/project_test.exs)
      tests=(test/forge/project_test.exs)
    elif [[ "$app" = engine ]]; then
      changed=(lib/engine/search/indexer.ex test/engine/search/indexer_test.exs
        lib/engine/code_intelligence/references.ex lib/engine/search/store/state.ex
        lib/engine/search/store/backends/ets.ex test/engine/search/store/backends/project_isolation_test.exs
        test/engine/code_intelligence/references_outcome_test.exs test/engine/code_intelligence/references_test.exs)
      tests=(test/engine/search/indexer_test.exs test/engine/code_intelligence/references_outcome_test.exs
        test/engine/code_intelligence/references_test.exs
        test/engine/search/store_test.exs test/engine/search/store/state_test.exs
        test/engine/search/store/backends/project_isolation_test.exs test/engine/search/store/backends/ets/state_test.exs)
    else
      changed=(lib/expert/logging/project_log_file.ex test/expert/logging/project_log_file_test.exs
        priv/build_engine.exs lib/expert.ex lib/expert/provider/handlers/find_references.ex
        test/expert/expert_test.exs test/expert/provider/handlers/find_references_test.exs)
      tests=(test/expert/logging/project_log_file_test.exs test/expert/expert_test.exs
        test/expert/provider/handlers/find_references_test.exs)
    fi
    unbuffer mix format --check-formatted "${changed[@]}"
    unbuffer mix credo --strict "${changed[@]}"
    unbuffer mix test --warnings-as-errors "${tests[@]}"
  )
done
(
  cd apps/expert
  MIX_ENV=prod unbuffer mix deps.get
  MIX_ENV=prod unbuffer mix release plain
)
mkdir -p "$tools_dir/bin" "$tools_dir/releases"
mv apps/expert/_build/prod/rel/plain "$release_dir"
printf 'upstream=%s\npatch_sha256=%s\n' "$revision" "$hash" > "$release_dir/tips-build.txt"
# Preserve an existing vendor binary for rollback; installs replace only the symlink.
if [[ -f "$tools_dir/bin/expert" && ! -L "$tools_dir/bin/expert" ]]; then
  cp -p "$tools_dir/bin/expert" "$tools_dir/releases/expert-before-$version"
fi
staged_link="$tools_dir/bin/.expert-$$"
ln -s "../releases/expert-$version/bin/start_expert" "$staged_link"
mv -f "$staged_link" "$tools_dir/bin/expert"
staged_link=""
printf 'Installed Expert %s at %s/bin/expert\n' "$version" "$tools_dir"
