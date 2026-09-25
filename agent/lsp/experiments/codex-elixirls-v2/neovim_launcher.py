#!/usr/bin/env python3
"""Own one headless Neovim and the published vv-mcp stdio server per session.

MCP bytes pass directly to vv-mcp; this launcher implements no protocol tools.
Eager startup lets post-edit hooks work without a model first calling an LSP tool.
"""

import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Generator
from contextlib import ExitStack, contextmanager, suppress
from pathlib import Path
from typing import BinaryIO, TextIO, TypedDict, cast

# Neovim's compiler cleanup (neovim_owner.lua) sends its final SIGKILL within
# about 2.2 s. Past this, the editor is stalled: stop it and all listed groups.
EDITOR_EXIT_SECONDS = 2.5
# A client restarted at once waits for the old session's cleanup instead of
# failing its MCP handshake. A live session is still refused within this bound.
LOCK_WAIT_SECONDS = 3


class RegistryEntry(TypedDict):
    pid: int
    socket: str
    kind: str
    instanceId: str


class Arguments(argparse.Namespace):
    vendor: Path
    workspace: Path
    environment: Path


def write_record(path: Path, value: object) -> None:
    """Publish whole records so a killed writer cannot leave partial JSON."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(json.dumps(value) + "\n")
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def defer_termination() -> Generator[None, None, None]:
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


@contextmanager
def locks(paths: tuple[Path, ...], deadline: float = 0) -> Generator[tuple[int, ...], None, None]:
    """Kernel-owned lifetime, no PID records or process-identity heuristics."""
    with ExitStack() as stack:
        handles: list[TextIO] = []
        for path in dict.fromkeys(paths):
            path.parent.mkdir(parents=True, exist_ok=True)
            handle = stack.enter_context(path.open("a+"))
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError as error:
                    if time.monotonic() >= deadline:
                        raise RuntimeError(
                            "An existing session owns "
                            + str(path)
                            + "; wait for it to stop before reconnecting"
                        ) from error
                    time.sleep(0.05)
            handles.append(handle)
        yield tuple(handle.fileno() for handle in handles)


def server_lock_paths(root: Path, state: Path) -> tuple[Path, Path]:
    return root / ".elixir_ls/server.lock", state / "server.lock"


@contextmanager
def ownership(root: Path, state: Path) -> Generator[tuple[int, ...], None, None]:
    """Own both directories through cleanup; reject an orphaned compiler too."""
    root, state = root.resolve(strict=True), state.resolve()
    if not (root / "mix.exs").is_file():
        raise ValueError("Workspace must contain mix.exs")
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    with locks((root / ".elixir_ls/session.lock", state / "session.lock"), deadline) as lock_fds:
        # The server takes these independently before exec, keeping them for its
        # lifetime even if Neovim/launcher die. Its start also uses LOCK_NB.
        with locks(server_lock_paths(root, state), deadline):
            pass
        (state / "owner.json").unlink(missing_ok=True)
        yield lock_fds


def registration(nvim: subprocess.Popen[bytes], registry: Path, socket: str) -> RegistryEntry:
    """Wait for our registry entry, not compiler readiness."""
    deadline = time.monotonic() + 5
    entry_path = registry / f"{nvim.pid}.json"
    while True:
        if nvim.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError("Owned Neovim failed to register within five seconds")
        try:
            entry = cast(RegistryEntry, json.loads(entry_path.read_text()))
            if (
                entry["pid"] == nvim.pid
                and entry["socket"] == socket
                and entry["kind"] == "interactive"
            ):
                return entry
        except (OSError, ValueError, KeyError):
            pass  # Registration may not exist yet.
        time.sleep(0.02)


def forward_stdin(stream: BinaryIO) -> None:
    """Forward raw MCP bytes; give the bridge EOF if its launcher is killed."""
    try:
        while data := os.read(sys.stdin.fileno(), 65536):
            stream.write(data)
            stream.flush()
    except (BrokenPipeError, OSError):
        pass  # The bridge may have exited first; the lifecycle monitor handles it.
    finally:
        stream.close()


def process_groups(leader: int) -> set[int]:
    """Our Neovim group plus the groups started below it.

    OTP starts port programs (rebar3, make, System.cmd) in new sessions, so they
    leave our group. List them while the process tree still links them to us.
    """
    try:
        # Fixed system tool and arguments, no shell.
        table = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
            capture_output=True,
            text=True,
            check=True,
            timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError) as error:
        print(f"ElixirLS session: cannot list compiler processes: {error}", file=sys.stderr)
        return {leader}
    fields = [line.split() for line in table.splitlines()]
    rows = [[int(v) for v in row] for row in fields if len(row) == 3 and all(map(str.isdigit, row))]
    children: dict[int, list[tuple[int, int]]] = {}
    for pid, parent, group in rows:
        children.setdefault(parent, []).append((pid, group))
    # Start from every member: the compiler can outlive an editor that already exited.
    pending = [leader, *(pid for pid, _, group in rows if group == leader)]
    groups, seen = {leader}, set[int]()
    while pending:
        pid = pending.pop()
        if pid not in seen:
            seen.add(pid)
            for child, group in children.get(pid, []):
                groups.add(group)
                pending.append(child)
    return groups


def remembered_groups(path: Path, editor: int) -> set[int]:
    """Groups this session's neovim_owner.lua published while the tree linked them to it."""
    try:
        owner, *groups = [int(line) for line in path.read_text().split()]
    except (OSError, ValueError):
        return set()
    return set(groups) if owner == editor else set()


def signal_groups(groups: set[int], number: int) -> set[int]:
    """Signal each group; return those that still exist."""
    alive = set[int]()
    for group in groups:
        # macOS returns EPERM for a group when only zombies remain; zombies do not write.
        # These owned, same-user children do not change credentials.
        with suppress(ProcessLookupError, PermissionError):
            os.killpg(group, number)
            alive.add(group)
    return alive


def cleanup(
    nvim: subprocess.Popen[bytes] | None,
    bridge: subprocess.Popen[bytes] | None,
    remembered: Path,
) -> None:
    """No RPC: teardown must also work when the peer is stalled."""
    if bridge is not None and bridge.poll() is None:
        bridge.terminate()
        try:
            bridge.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait()
    if nvim is not None:
        # Fallback list, taken before a crash or exit can orphan port programs.
        groups = process_groups(nvim.pid)
        if nvim.stdin is not None:
            nvim.stdin.close()
        # On EOF Neovim stops its own compiler tree (neovim_owner.lua: LSP exit,
        # TERM, 1.5 s grace, KILL). That also covers a client that kills this launcher first.
        with suppress(subprocess.TimeoutExpired):
            nvim.wait(timeout=EDITOR_EXIT_SECONDS)
        # A stalled, hung or killed editor, or a failed editor cleanup: stop what we
        # listed and what Neovim remembered. SIGKILL cannot be caught: keep the locks
        # until those groups are gone.
        groups |= remembered_groups(remembered, nvim.pid)
        # Only real groups: never init's or this launcher's own. killpg(-N) would signal PID N.
        groups = {group for group in groups if group > 1} - {os.getpgrp()}
        while signal_groups(groups, signal.SIGKILL):
            time.sleep(0.05)
        nvim.wait(timeout=2)


def launch(vendor: Path, root: Path, environment: Path, lock_fds: tuple[int, ...]) -> None:
    env = os.environ | cast(dict[str, str], json.loads(environment.read_text()))
    fd, socket = tempfile.mkstemp(prefix="elixir-nvim-", suffix=".sock")
    os.close(fd)
    os.unlink(socket)
    nvim: subprocess.Popen[bytes] | None = None
    bridge: subprocess.Popen[bytes] | None = None
    owner_path = Path(env["VV_MCP_REGISTRY"]).parent / "owner.json"
    remembered = owner_path.parent / "compiler-groups"
    # Group IDs from an earlier session may belong to other processes now.
    remembered.unlink(missing_ok=True)
    published_owner = False

    def terminate(*_: object) -> None:
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        with environment.with_suffix(".nvim.log").open("w") as log:
            with defer_termination():
                # Fixed bundled executable, argument array, no shell; root is canonical.
                nvim = subprocess.Popen(  # noqa: S603
                    [
                        str(vendor / "nvim-macos-arm64/bin/nvim"),
                        "--embed",
                        "--headless",
                        "--listen",
                        socket,
                        str(root / "mix.exs"),
                    ],
                    cwd=root,
                    env=env,
                    stdin=subprocess.PIPE,
                    stdout=log,
                    stderr=log,
                    start_new_session=True,
                    pass_fds=lock_fds,
                )
            entry = registration(nvim, Path(env["VV_MCP_REGISTRY"]), socket)
            write_record(owner_path, entry)
            # Registration starts a new one-time failure-delivery window. An
            # earlier startup hook may have reported the missing registration.
            (owner_path.parent / "feedback-unavailable").unlink(missing_ok=True)
            published_owner = True
            environment.with_suffix(".startup.json").write_text(
                json.dumps(
                    {
                        "status": "registered",
                        "instanceId": entry["instanceId"],
                        "message": "Compiler readiness is reported by hooks and MCP tools.",
                    }
                )
                + "\n"
            )
            # The bound server never falls back to a managed replacement.
            # Fixed bundled executable and our verified instance, without a shell.
            bridge = subprocess.Popen(  # noqa: S603
                [str(vendor / "vv-mcp"), "--instance-id", entry["instanceId"]],
                cwd=root,
                env=env,
                stdin=subprocess.PIPE,
            )

            # A private pipe gives vv-mcp EOF even if this launcher is killed.
            # Forward raw bytes; vv-mcp remains the only MCP implementation.
            if bridge.stdin is None:
                raise RuntimeError("MCP input pipe was not created")
            threading.Thread(target=forward_stdin, args=(bridge.stdin,), daemon=True).start()
            while bridge.poll() is None:
                if nvim.poll() is not None:
                    raise RuntimeError("Owned Neovim exited; this MCP session is unavailable")
                time.sleep(0.05)
            raise SystemExit(bridge.returncode)
    finally:
        # A second termination signal must not interrupt the cleanup it requested.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        cleanup(nvim, bridge, remembered)
        remembered.unlink(missing_ok=True)
        if published_owner:
            owner_path.unlink(missing_ok=True)
        Path(socket).unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--environment", type=Path, required=True)
    args = parser.parse_args(namespace=Arguments())
    root, vendor = args.workspace.resolve(), args.vendor.resolve()
    state = Path(json.loads(args.environment.read_text())["VV_MCP_REGISTRY"]).parent
    with ownership(root, state) as lock_fds:
        launch(vendor, root, args.environment, lock_fds)


if __name__ == "__main__":
    main()
