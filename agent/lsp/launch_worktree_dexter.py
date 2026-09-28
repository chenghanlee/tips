#!/usr/bin/env python3
"""Run one Dexter MCP session in an explicitly assigned Git worktree."""

import fcntl
import os
import shutil
import subprocess
import sys
from pathlib import Path


def launch(workspace: Path) -> None:
    workspace = workspace.resolve(strict=True)
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("git is required")
    result = subprocess.run(
        [git, "-C", str(workspace), "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    if Path(result.stdout.strip()).resolve() != workspace or not (workspace / "mix.exs").is_file():
        raise RuntimeError("workspace must be the root of a Git checkout containing mix.exs")

    # Sharing tool installations is fine. Sharing mutable project trees is not.
    for name in ("deps", "_build", ".dexter"):
        if (workspace / name).is_symlink():
            raise RuntimeError(f"refusing shared/symlinked project directory: {workspace / name}")

    bridge = Path(os.environ.get("TIPS_ELIXIR_TOOLS", str(Path(__file__).parent / "vendor")))
    bridge = (bridge / "bin/mcp-language-server").resolve(strict=True)
    server = shutil.which(os.environ.get("TIPS_DEXTER_COMMAND", "dexter"))
    if server is None:
        raise RuntimeError("dexter is required on PATH (or set TIPS_DEXTER_COMMAND)")

    state = workspace / ".dexter"
    state.mkdir(exist_ok=True)
    # This advisory lock coordinates these launchers, not unrelated editors.
    lock_path = state / "codex.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(descriptor)
        raise RuntimeError(f"a Dexter Codex session already owns {workspace}") from error

    # Keep ownership for the entire bridge lifetime, including client shutdown.
    os.set_inheritable(descriptor, True)
    # Dexter 0.7.2 searches ancestor database markers before Git roots, even
    # with an explicit CLI path. An empty local SQLite file pins this root.
    for name in ("dexter.db", "dexter.db-wal", "dexter.db-shm"):
        if (state / name).is_symlink():
            raise RuntimeError(f"refusing symlinked Dexter state: {state / name}")
    database = os.open(state / "dexter.db", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    os.close(database)
    environment = os.environ.copy()
    for name in ("MIX_BUILD_PATH", "MIX_BUILD_ROOT", "MIX_DEPS_PATH"):
        environment.pop(name, None)
    environment.setdefault("MIX_ENV", "test")
    os.chdir(workspace)
    os.execve(
        bridge,
        [
            str(bridge), "--workspace", str(workspace), "--lsp", server,
            "--dexter", "--", "lsp", str(workspace),
        ],
        environment,
    )


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise RuntimeError("usage: launch_worktree_dexter.py /absolute/worktree")
        launch(Path(sys.argv[1]))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Dexter launch refused: {exc}", file=sys.stderr)
        sys.exit(1)
