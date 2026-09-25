"""Seed a new worktree's private ElixirLS build with dependencies normal Mix compiled.

Without this, ElixirLS compiles every dependency a second time into `.elixir_ls/build`.
Compiled dependencies name their sources under this worktree's `deps/`, so a copy
made within one worktree keeps definitions local; a copy from another worktree
does not. ElixirLS's first build still checks each copy's Elixir/OTP version, lock,
marker and app file, and recompiles anything Mix left unfinished.

Run it before the client starts, never inside `serve`: Mix takes about a minute on
a new worktree and must not delay MCP startup or touch the MCP stdio stream.
"""

import gzip
import os
import shutil
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import TypedDict

# ElixirLS defaults to MIX_ENV=test; the adapter does not choose another environment.
ENV = "test"
STAGING = ".seed-"

type Copy = Callable[[str, str], object]
type Tree = dict[str, tuple[int, int, int, str]]


class Report(TypedDict):
    status: str
    detail: str
    seeded: list[str]
    skipped: dict[str, str]
    seconds: dict[str, float]


def report(status: str, detail: str, seconds: dict[str, float]) -> Report:
    return {"status": status, "detail": detail, "seeded": [], "skipped": {}, "seconds": seconds}


def build_lib(workspace: Path, kind: str) -> Path:
    return workspace / (".elixir_ls/build" if kind == "elixir_ls" else "_build") / ENV / "lib"


def dependencies(workspace: Path) -> list[str]:
    """Normal Mix builds that have a `deps/` source; the project application has none."""
    built = build_lib(workspace, "mix")
    if not built.is_dir():
        return []
    return sorted(
        path.name
        for path in built.iterdir()
        if path.is_dir() and not path.is_symlink() and (workspace / "deps" / path.name).is_dir()
    )


def seeded_already(workspace: Path) -> bool:
    """ElixirLS or an earlier seed owns this build; never overwrite it."""
    lib = build_lib(workspace, "elixir_ls")
    return lib.is_dir() and any((workspace / "deps" / path.name).is_dir() for path in lib.iterdir())


def tree(root: Path) -> Tree:
    """Everything a concurrent writer would change, without reading file contents."""
    entries: Tree = {}
    for directory, names, files in os.walk(root):
        for name in names + files:
            path = Path(directory, name)
            info = path.lstat()
            link = os.readlink(path) if path.is_symlink() else ""
            entries[str(path.relative_to(root))] = (
                info.st_mode,
                info.st_size,
                info.st_mtime_ns,
                link,
            )
    return entries


def retarget_links(source: Path, staging: Path) -> None:
    """Mix's relative priv/include/src links assume `_build/<env>/lib/<app>`'s depth.

    The ElixirLS build is one directory deeper. Point each link that leaves the
    copied tree at the same target from its new location; staging and the final
    directory are siblings, so both have that depth.
    """
    for directory, names, files in os.walk(staging):
        for name in names + files:
            link = Path(directory, name)
            target = os.readlink(link) if link.is_symlink() else ""
            if not target or os.path.isabs(target):
                continue
            original = source / link.relative_to(staging)
            resolved = os.path.normpath(os.path.join(original.parent, target))
            if Path(resolved).is_relative_to(source):
                continue
            link.unlink()
            link.symlink_to(os.path.relpath(resolved, link.parent))


def names_sources(build: Path, sources: Path) -> bool:
    """Every BEAM records its absolute source. A `_build` copied from another checkout
    names that checkout; `mix deps.compile` rebuilds its Elixir modules but can keep
    Erlang ones, so one dependency can mix both.
    """
    marker = str(sources).encode() + b"/"
    for beam in build.rglob("*.beam"):
        data = beam.read_bytes()
        if data[:2] == b"\x1f\x8b":  # Erlang's `compressed` option, e.g. idna's tables.
            try:
                data = gzip.decompress(data)
            except (OSError, EOFError):
                return False
        if marker not in data:
            return False
    return True


def drop_build_manifests(staging: Path, build: Path) -> None:
    """Mix's Erlang manifest lists outputs by absolute path in the normal build.

    A later compile in the ElixirLS build would delete those files there. Without
    the manifest, Mix recompiles such a dependency from scratch if it ever must.
    """
    marker = str(build).encode() + b"/"
    for manifest in (staging / ".mix").glob("*"):
        if manifest.is_file() and marker in manifest.read_bytes():
            manifest.unlink()


def seed_one(source: Path, destination: Path, sources: Path, copy: Copy) -> str | None:
    """Publish one complete copy with a single rename, or nothing; returns a skip reason."""
    if destination.exists() or destination.is_symlink():
        return "present"
    staging = destination.with_name(STAGING + destination.name + "-" + uuid.uuid4().hex)
    try:
        before = tree(source)
        if not names_sources(source, sources):
            return "a BEAM does not name " + str(sources)
        shutil.copytree(source, staging, symlinks=True, copy_function=copy)
        retarget_links(source, staging)
        drop_build_manifests(staging, source.parents[2])
        # Normal Mix locks `_build/<env>` only; it never excludes this reader.
        if tree(source) != before:
            return "changed during copy"
        staging.rename(destination)
        return None
    except OSError as error:
        # copytree lists every failed file: tens of KB while Mix rebuilds a dependency.
        return ("copy failed: " + str(error))[:500]
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def discard_staging(lib: Path) -> None:
    """A killed copy leaves only hidden staging, which Mix ignores; remove it."""
    for stale in lib.glob(STAGING + "*"):
        shutil.rmtree(stale, ignore_errors=True)


def seed(workspace: Path, copy: Copy = shutil.copy2) -> Report:
    """Call with session ownership held, so no ElixirLS is using this build."""
    start = time.monotonic()
    # Compiled sources name physical paths; compare against the same form.
    workspace = workspace.resolve(strict=True)
    lib = build_lib(workspace, "elixir_ls")
    lib.mkdir(parents=True, exist_ok=True)
    # The file ElixirLS writes at startup; hide the seeded build from Git until then.
    ignore = workspace / ".elixir_ls/.gitignore"
    if not ignore.exists():
        ignore.write_text("*")
    discard_staging(lib)
    result = report("seeded", "", {})
    for name in dependencies(workspace):
        source, sources = build_lib(workspace, "mix") / name, workspace / "deps" / name
        reason = seed_one(source, lib / name, sources, copy)
        if reason:
            result["skipped"][name] = reason
        else:
            result["seeded"].append(name)
    result["seconds"]["seed"] = time.monotonic() - start
    if not result["seeded"]:
        result["status"] = "not-seeded"
        result["detail"] = "No compiled dependency could be copied"
    return result


def project_mix(bundle: Path) -> Path:
    """The agent's own Mix from PATH; the bundle's private compiler stays inside ElixirLS."""
    found = shutil.which("mix")
    if not found:
        raise RuntimeError("Project Mix is not on PATH")
    if Path(found).resolve().is_relative_to(bundle.resolve()):
        raise RuntimeError("PATH selects the bundle's private Mix: " + found)
    return Path(found)


def mix(workspace: Path, executable: Path, arguments: list[str]) -> str:
    """Normal project Mix with the caller's environment; returns an error or "".

    No input, so an install prompt fails instead of waiting; output goes to stderr,
    keeping the caller's stdout clean. No timeout: an interrupt reaches Mix's whole
    process group, which killing only `mix` would not.
    """
    try:
        # Resolved normal-toolchain executable and fixed task arguments; no shell.
        result = subprocess.run(  # noqa: S603
            [str(executable), *arguments],
            cwd=workspace,
            env=os.environ | {"MIX_ENV": ENV},
            stdin=subprocess.DEVNULL,
            stdout=2,
            check=False,
        )
    except OSError as error:
        return f"mix {arguments[0]} did not start: {error}"
    return f"mix {arguments[0]} exited {result.returncode}" if result.returncode else ""


def toolchain(elixir: Path) -> str:
    """Elixir version and OTP major, as Mix records them for each dependency."""
    # Resolved normal-toolchain executable and a fixed expression; no shell.
    return subprocess.run(  # noqa: S603
        [str(elixir), "-e", 'IO.write(System.version() <> "/" <> System.otp_release())'],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    ).stdout


def prepare(workspace: Path, bundle: Path, expected: str) -> Report:
    """Fetch and compile dependencies with project Mix, then seed ElixirLS's build.

    `expected` is the bundle's `<elixir>/<otp>` version. Hold session ownership and
    finish before the agent can run Mix here. Every failure leaves ElixirLS to
    compile dependencies itself, as without seeding.
    """
    workspace = workspace.resolve(strict=True)
    if seeded_already(workspace):
        # ElixirLS compiles any dependency an interrupted seed did not publish.
        discard_staging(build_lib(workspace, "elixir_ls"))
        return report("ready", "ElixirLS build already has dependencies", {})
    elixir, otp = expected.split("/")
    try:
        executable = project_mix(bundle)
        found = toolchain(executable.with_name("elixir"))
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        return report("not-seeded", f"Cannot use the project toolchain: {error}", {})
    if found != elixir + "/" + otp.split(".")[0]:
        return report("not-seeded", f"Project toolchain {found} differs from {expected}", {})
    seconds: dict[str, float] = {}
    for step, arguments in (
        ("deps_get", ["deps.get", "--check-locked"]),
        ("deps_compile", ["deps.compile"]),
    ):
        start = time.monotonic()
        error = mix(workspace, executable, arguments)
        seconds[step] = time.monotonic() - start
        if error:
            return report("not-seeded", error, seconds)
    try:
        result = seed(workspace)
    except OSError as error:
        return report("not-seeded", f"Cannot prepare the ElixirLS build: {error}", seconds)
    result["seconds"] = seconds | result["seconds"]
    return result
