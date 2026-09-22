#!/usr/bin/env python3
"""Stage the parallel-worktree experiment without replacing installed tools.

Only bundled engine source and the build script change. Expert compiles that engine
on first use. The manager BEAM files and MCP bridge remain the installed versions.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installed-tools", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    installed = args.installed_tools.resolve()
    output = args.output.resolve()
    if output == installed or installed in output.parents:
        parser.error("Use a separate scratch directory outside installed tools")
    output.mkdir(parents=True, exist_ok=False)
    release = (installed / "bin/expert").resolve().parent.parent
    copy = ["cp", "-cR"] if os.uname().sysname == "Darwin" else ["cp", "-a"]
    subprocess.run(copy + [str(release), str(output / "release")], check=True)
    privs = list((output / "release/lib").glob("xp_expert-*/priv"))
    if len(privs) != 1:
        raise RuntimeError(f"Expected one Expert priv directory, got {privs}")
    priv = privs[0]
    stage = output / "patch-source"
    relative_paths = {
        "apps/engine/lib/engine/search/store/backends/ets.ex":
            priv / "engine_source/apps/engine/lib/engine/search/store/backends/ets.ex",
        "apps/expert/priv/build_engine.exs": priv / "build_engine.exs",
    }
    for relative, source in relative_paths.items():
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    patch = Path(__file__).with_name("expert-parallel-exploration.patch")
    subprocess.run(["patch", "--batch", "-p1", "-i", str(patch.resolve())],
                   cwd=stage, check=True)
    for relative, target in relative_paths.items():
        shutil.copy2(stage / relative, target)

    # Harness-only isolation, deliberately absent from the candidate source patch.
    builder = priv / "build_engine.exs"
    source = builder.read_text()
    original = "cache_dir = Keyword.fetch!(args, :cache_dir)"
    if source.count(original) != 1:
        raise RuntimeError("Build script cache argument changed; inspect before staging")
    builder.write_text(source.replace(
        original, 'cache_dir = System.fetch_env!("TIPS_EXPERT_TEST_CACHE")'))

    binaries = output / "tools/bin"
    binaries.mkdir(parents=True)
    shutil.copy2(installed / "bin/mcp-language-server", binaries / "mcp-language-server")
    wrapper = binaries / "expert"
    wrapper.write_text(
        '#!/bin/sh\nset -eu\n'
        'if [ "$#" -ne 1 ] || [ "$1" != "--stdio" ]; then\n'
        '  echo "Exploratory wrapper supports only --stdio; cache-management CLI is not isolated" >&2\n'
        '  exit 2\n'
        'fi\n'
        ': "${TIPS_EXPERT_TEST_CACHE:?Set an absolute disposable cache directory}"\n'
        'case "$TIPS_EXPERT_TEST_CACHE" in /*) ;; *) exit 2 ;; esac\n'
        'export HEX_HOME="$TIPS_EXPERT_TEST_CACHE/hex"\n'
        f'exec {shlex.quote(str(output / "release/bin/start_expert"))} "$@"\n')
    wrapper.chmod(0o755)
    metadata = {
        "installed_release": str(release),
        "release": str(output / "release"),
        "tools": str(output / "tools"),
        "builder": str(builder),
        "engine_source": str(priv / "engine_source/apps/engine"),
        "version": priv.parent.name.removeprefix("xp_expert-"),
        "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        "bridge_sha256": hashlib.sha256((binaries / "mcp-language-server").read_bytes()).hexdigest(),
        "test_only_shim": "build_engine.exs requires TIPS_EXPERT_TEST_CACHE",
        "tests": "Source tests are included in patch-source; the stager does not execute them",
    }
    (output / "exploration.json").write_text(json.dumps(metadata, indent=2))
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
