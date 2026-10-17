"""Find the Dexter binary and Elixir sources, and stop a project's Dexter daemon."""

import json
import os
import re
import time
from pathlib import Path

import config as conf
from commands import execute, object_fields, run


def dexter_binary() -> Path:
    home = Path(
        os.environ.get("TIPS_DEXTER_HOME", str(conf.main_checkout() / "agent/lsp/dexter"))
    ).resolve()
    binary = home / "vendor/dexter"
    if not os.access(binary, os.X_OK):
        raise RuntimeError(f"Missing executable: {binary}; run agent/lsp/dexter/build.sh.")
    return binary


def elixir_sources(cwd: Path) -> Path:
    """The Elixir standard-library sources Dexter indexes for a project."""
    version = run(
        "elixir",
        "--short-version",
        cwd=cwd,
        timeout=conf.settings()["timeouts"]["dexter_startup_seconds"],
    )
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError(f"Unexpected Elixir version: {version!r}")
    explicit = os.environ.get("DEXTER_ELIXIR_LIB_ROOT")
    sources = (
        Path(explicit)
        if explicit
        else conf.main_checkout() / "agent/lsp/vendor" / f"elixir-{version}" / "lib"
    )
    recorded = sources.parent / "VERSION"
    if (
        not (sources / "elixir/lib/enum.ex").is_file()
        or not recorded.is_file()
        or recorded.read_text().strip() != version
    ):
        raise RuntimeError(
            f"Elixir {version} sources are missing at {sources}; see agent/lsp/README.md."
        )
    return sources.resolve()


def tools() -> tuple[Path, Path, Path]:
    """Check the shared tools before reserving anything; return the Dexter binary, the
    shared skills and the Elixir sources."""
    binary, skills = dexter_binary(), conf.main_checkout() / ".agents/skills"
    if not skills.is_dir():
        raise RuntimeError("Shared skills directory is missing.")
    return binary, skills, elixir_sources(conf.main_checkout())


def daemon_alive(project: Path) -> bool:
    """Whether a Dexter daemon serves the project, by its process arguments."""
    rows = run("ps", "-A", "-ww", "-o", "args=").splitlines()
    return any(row.rstrip().endswith(f"dexter daemon {project}") for row in rows)


def dexter_invocation(binary: str, root: Path, sources: str) -> tuple[list[str], dict[str, str]]:
    """How to run Dexter for one project: its argv prefix and environment. bootstrap.py
    writes this into the project's wrapper and stop runs it directly; keep both here."""
    return [binary, "--root", str(root)], {"DEXTER_ELIXIR_LIB_ROOT": sources}


def stop_daemon(project: Path, config: Path) -> None:
    """Stop the project's Dexter daemon with the binary and sources its trusted bootstrap
    configuration names, never the project's wrapper, and confirm that it exited."""
    if not daemon_alive(project):
        return
    settings = object_fields(json.loads((config / "bootstrap.json").read_text()), "bootstrap")
    argv, extra = dexter_invocation(str(settings["dexter"]), project, str(settings["sources"]))
    result = execute(
        [*argv, "stop"],
        cwd=conf.state_dir(),
        env={**os.environ, **extra},
        timeout=conf.settings()["timeouts"]["dexter_startup_seconds"],
        input_text="",
    )
    if result.returncode:
        error = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"Dexter stop for {project} failed: {error}; the reservation is kept")
    deadline = time.monotonic() + conf.settings()["timeouts"]["shutdown_seconds"]
    while daemon_alive(project):
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Dexter still serves {project}; the reservation is kept")
        time.sleep(0.1)
