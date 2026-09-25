#!/usr/bin/env python3
"""Bounded synchronous compiler feedback; Stop rechecks an edit left pending."""

import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import TypedDict, cast

ENTERED = time.monotonic()
DEADLINE = "hook deadline reached while waiting for feedback"
# Lua errors, including JSON encoding, come back as data. A non-zero client exit then means
# the client could not reach Neovim or lost it.
COLLECT = (
    "(function(a) local ok, v = pcall(function() return vim.json.encode("
    "require('neovim_sync').collect(a[1], a[2], a[3])) end) "
    "return ok and v or vim.json.encode({ lua_error = tostring(v) }) end)(_A)"
)
# The bundled client's fixed texts when it cannot connect or Neovim goes away.
CONNECT_FAILED, PEER_CLOSED = "E247:", "was closed by the peer"


class Arguments(argparse.Namespace):
    vendor: Path
    registry: Path
    workspace: Path
    budget_ms: int
    audit: Path | None


class RegistryEntry(TypedDict):
    roots: list[str]
    cwd: str
    kind: str
    pid: int
    socket: str
    instanceId: str


def session_socket(registry: Path, root: Path) -> str:
    owner = cast(RegistryEntry, json.loads((registry.parent / "owner.json").read_text()))
    entries = [
        cast(RegistryEntry, json.loads(path.read_text())) for path in registry.glob("*.json")
    ]
    if not entries:
        raise ConnectionError("No Neovim instance is registered for this session")
    entries = [
        entry
        for entry in entries
        if any(Path(path).resolve() == root for path in entry.get("roots", []))
        or Path(entry["cwd"]).resolve() == root
    ]
    if len(entries) != 1:
        raise RuntimeError(f"Expected one Neovim for the assigned workspace; found {len(entries)}")
    entry = entries[0]
    if entry["kind"] != "interactive" or any(
        entry[key] != owner[key] for key in ("instanceId", "pid", "socket")
    ):
        raise RuntimeError("Neovim instance differs from the session owner; restart the session")
    return entry["socket"]


def left(stop_at: float) -> float:
    """Seconds until `stop_at`, checked before the client runs and after it returns."""
    seconds = stop_at - time.monotonic()
    if seconds <= 0:
        raise TimeoutError(DEADLINE)
    return seconds


def request(nvim: Path, path: str, stop_at: float, *args: object) -> dict[str, object]:
    """Run `collect` once through Neovim's own client; the child is killed at `stop_at`."""
    # A Vim list literal; the event name is one of three fixed words, the rest are numbers.
    expression = f'luaeval("{COLLECT}", {json.dumps(list(args))})'
    timeout = left(stop_at)  # Outside the try: TimeoutError is an OSError.
    try:
        done = subprocess.run(  # noqa: S603 - fixed bundle binary, fixed expression
            [nvim, "--clean", "--server", path, "--remote-expr", expression],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(DEADLINE) from error
    except OSError as error:  # A broken bundle is not a lost Neovim.
        raise RuntimeError(f"Neovim client could not start: {error}") from error
    if done.returncode != 0:
        lines = done.stderr.decode(errors="replace").strip().splitlines()
        error = lines[0].rstrip(".") if lines else f"Neovim client exited {done.returncode}"
        # Only a recognized lost connection is reported as disconnected, once.
        if error.startswith(CONNECT_FAILED) or error.endswith(PEER_CLOSED):
            raise ConnectionError(error)
        raise RuntimeError(error)
    reply: object = json.loads(done.stdout.decode(errors="surrogateescape"))
    if not isinstance(reply, dict):
        raise TypeError("Expected a compiler feedback object from Neovim")
    left(stop_at)  # Decoding takes time too; accept nothing after the cutoff.
    result = cast(dict[str, object], reply)
    if "lua_error" in result:
        raise RuntimeError(result["lua_error"])
    return result


def collect(args: Arguments, name: str) -> tuple[dict[str, object], str, bool, dict[str, float]]:
    root = args.workspace.resolve()
    start = ENTERED
    deadline = start + args.budget_ms / 1000
    # The budget includes imports, connection and RPC, not just compiler wait.
    # The client process has a timeout, not a signal: library code can catch a
    # signal's exception. Leave a small output allowance when Neovim never answers.
    stop_at = deadline - 0.1
    phases: dict[str, float] = {}
    result: dict[str, object] = {}
    rpc_failed = False
    try:
        path = session_socket(args.registry, root)
        # Budget covers scan + wait, with 300 ms for RPC, teardown and output.
        # Unix expiry also rejects a request queued behind another RPC. Lua uses
        # its own monotonic elapsed time; no shared monotonic epoch is assumed.
        remaining_ms = max(0, int((deadline - time.monotonic()) * 1000) - 300)
        expires_at = time.time() + remaining_ms / 1000
        nvim = args.vendor.resolve() / "nvim-macos-arm64/bin/nvim"
        result = request(nvim, path, stop_at, remaining_ms, name, expires_at)
        phases["rpc_return_ms"] = round((time.monotonic() - start) * 1000, 3)
        if result["status"] == "expired":
            raise TimeoutError("hook deadline reached before feedback could be collected")
        message = result["message"]
        if not isinstance(message, str):
            raise TypeError("Expected a compiler feedback message from Neovim")
    except Exception as error:
        rpc_failed = True
        # A deadline alone is not evidence that the session stopped.
        advice = (
            "Feedback could not be confirmed within the hook budget; validation remains unfinished."
            if isinstance(error, TimeoutError)
            else "If the session has stopped, restart the coding client in this worktree "
            "to reconnect."
        )
        message = (
            f"ElixirLS feedback unavailable: {error}. {advice} "
            "This does not mean the source is error-free."
        )
        result = {"status": "unavailable", "message": message}
        if isinstance(error, (FileNotFoundError, ConnectionError, EOFError)):
            result["disconnected"] = True
    finally:
        phases["closed_ms"] = round((time.monotonic() - start) * 1000, 3)
    return result, message, rpc_failed, phases


def disconnection_message(state: Path, message: str) -> str:
    """Report a stopped session once, including at Stop, until the next launch."""
    state.mkdir(parents=True, exist_ok=True)
    try:
        with (state / "feedback-unavailable").open("x") as marker:
            marker.write(message + "\n")
    except FileExistsError:
        return ""
    return message


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--budget-ms", type=int, default=5000)
    parser.add_argument("--audit", type=Path)
    args = parser.parse_args(namespace=Arguments())
    if not 1 <= args.budget_ms <= 5000:
        parser.error("--budget-ms must be between 1 and 5000")
    event = cast(dict[str, object], json.load(sys.stdin))
    name = str(event.get("hook_event_name", ""))
    if name not in {"PostToolUse", "PostToolUseFailure", "Stop"}:
        print("{}")
        return
    result, message, rpc_failed, phases = collect(args, name)
    if result.get("disconnected"):
        message = disconnection_message(args.registry.parent, message)
    if args.audit and message:
        # Test-only unpredictable marker proves the model actually received hook output.
        message += "\nFeedback receipt: " + uuid.uuid4().hex[:12]
    if name == "Stop":
        # If Neovim is gone it cannot remember that Stop already reported failure.
        # A disconnection is still reported once: its marker limits delivery.
        repeat_failure = (
            rpc_failed and event.get("stop_hook_active", False) and not result.get("disconnected")
        )
        output = {"decision": "block", "reason": message} if message and not repeat_failure else {}
    else:
        output = (
            {"hookSpecificOutput": {"hookEventName": name, "additionalContext": message}}
            if message
            else {}
        )
    if args.audit:
        with args.audit.open("a") as file:
            file.write(
                json.dumps(
                    {
                        "event": name,
                        "tool": event.get("tool_name"),
                        "result": result,
                        "output": output,
                        "phases": phases,
                        "seconds": round(time.monotonic() - ENTERED, 3),
                    }
                )
                + "\n"
            )
    print(json.dumps(output))


if __name__ == "__main__":
    main()
