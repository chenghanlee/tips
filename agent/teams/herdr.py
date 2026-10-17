"""Run Herdr, parse its answers and stop a pane's client and the processes it owns."""

import json
import os
import signal
import subprocess
import time
from pathlib import Path
from typing import cast

import config as conf
from commands import object_fields, object_list, require_type, run
from config import Entity, HerdrResult, ProcessInfo, ProcessRows


def entity_fields(value: object, label: str) -> None:
    fields = object_fields(value, label)
    for key, annotation in Entity.__annotations__.items():
        if key in fields and fields[key] is not None:
            if annotation is str:
                require_type(fields[key], str, f"{label}.{key}")
            else:
                object_fields(fields[key], f"{label}.{key}")


def parse_herdr(output: str) -> HerdrResult:
    envelope = object_fields(json.loads(output), "Herdr response")
    if "error" in envelope:
        raise RuntimeError(str(envelope["error"]))
    result = object_fields(envelope.get("result"), "Herdr result")
    for key in ("agent", "pane", "root_pane", "workspace", "tab"):
        if key in result:
            entity_fields(result[key], f"Herdr {key}")
    for key in ("agents", "panes", "workspaces"):
        if key in result:
            for item in object_list(result[key], f"Herdr {key}"):
                entity_fields(item, f"Herdr {key} entry")
    if "process_info" in result:
        validate_process_info(result["process_info"])
    return cast(HerdrResult, result)


def validate_process_info(value: object) -> None:
    info = object_fields(value, "Herdr process_info")
    require_type(info.get("shell_pid"), int, "Herdr shell_pid")
    require_type(info.get("foreground_process_group_id"), int, "Herdr foreground_process_group_id")
    for process in object_list(info.get("foreground_processes"), "Herdr foreground_processes"):
        require_type(process.get("pid"), int, "Herdr process pid")
        if "cwd" in process:
            require_type(process["cwd"], str, "Herdr process cwd")
        if "argv0" in process:
            require_type(process["argv0"], str, "Herdr process argv0")


def herdr(*args: str) -> HerdrResult:
    output = run("herdr", *args, timeout=conf.settings()["timeouts"]["launch_seconds"])
    if args[:2] == ("pane", "run"):
        return cast(HerdrResult, {})  # pane run succeeds with empty stdout.
    return parse_herdr(output)


def session_id(agent: Entity) -> str:
    """The client's own session id as Herdr reports it; empty when Herdr has none yet."""
    session = agent.get("agent_session")
    value = session.get("value") if session else None
    return value if isinstance(value, str) else ""


def processes() -> ProcessRows:
    # Find descendants through parent links. Expert engines may create their own process groups.
    rows: ProcessRows = {}
    for line in run("ps", "-axo", "pid=,ppid=,stat=,lstart=").splitlines():
        pid, parent, state, started = line.split(None, 3)
        if not state.startswith("Z"):
            rows[int(pid)] = (int(parent), started)
    return rows


def descendants(rows: ProcessRows, root: int) -> set[int]:
    owned = {root}
    while True:
        found = {pid for pid, (parent, _) in rows.items() if parent in owned}
        if found <= owned:
            return owned - {root}
        owned |= found


def occupant(pane: str, info: ProcessInfo) -> tuple[Path, bool]:
    """A pane's root and whether a client holds it.

    The client leads the pane's foreground process group; LSP servers and other children
    share the group but may run elsewhere. A bare shell leads its own group.
    """
    leader = info["foreground_process_group_id"]
    leaders = [p for p in info["foreground_processes"] if p["pid"] == leader and p.get("cwd")]
    if len(leaders) != 1:
        raise RuntimeError(f"{pane}: cannot identify the foreground client; preserved")
    return Path(leaders[0]["cwd"]).resolve(), leader != info["shell_pid"]


def pane_occupant(pane: str) -> tuple[Path, bool]:
    return occupant(pane, herdr("pane", "process-info", "--pane", pane)["process_info"])


def stop(pane: str, root: str | Path) -> None:
    root = Path(root)
    if not root.is_absolute():
        raise RuntimeError("stop_agent requires an absolute worktree root")
    root = root.resolve()
    current = herdr("pane", "get", pane)["pane"]
    info = herdr("pane", "process-info", "--pane", pane)["process_info"]
    foreground = info["foreground_processes"]
    shell = info["shell_pid"]
    rows = processes()
    clients = {p["pid"] for p in foreground if rows.get(p["pid"], (None,))[0] == shell}
    client_info = [p for p in foreground if p["pid"] in clients or p["pid"] == shell]
    if not client_info or any(Path(p.get("cwd", "")).resolve() != root for p in client_info):
        raise RuntimeError(f"{pane}: client root does not match {root}; preserved")
    owned = descendants(rows, shell)
    if os.getpid() in owned:
        raise RuntimeError(f"{pane}: cannot stop the calling agent; ask the dispatcher to stop it")
    identity = {pid: rows[pid][1] for pid in owned if pid in rows}
    signal_client(pane, current, clients, owned)
    wait_for_exit(pane, shell, identity)
    release_name(pane, current)
    print(f"{pane}: client and owned descendants exited")


def signal_client(pane: str, current: Entity, clients: set[int], owned: set[int]) -> None:
    if clients:
        if (
            current.get("agent") not in ("claude", "codex")
            or len(clients) != 1
            or not clients <= owned
        ):
            raise RuntimeError(f"{pane}: cannot establish owned client; preserved")
        for pid in clients:
            # SIGTERM asks the client to exit; it is never sent to an LSP or BEAM group.
            os.kill(pid, signal.SIGTERM)
    elif current.get("agent"):
        raise RuntimeError(f"{pane}: agent/process state disagrees; preserved")


def wait_for_exit(pane: str, shell: int, identity: dict[int, str]) -> None:
    deadline = time.monotonic() + conf.settings()["timeouts"]["shutdown_seconds"]
    while True:
        rows = processes()
        # Include children born during graceful shutdown, while their parent is still known.
        for parent in (shell, *identity):
            if parent == shell or rows.get(parent, (None, None))[1] == identity[parent]:
                for pid in descendants(rows, parent):
                    identity.setdefault(pid, rows[pid][1])
        alive = [
            pid for pid, started in identity.items() if rows.get(pid, (None, None))[1] == started
        ]
        if not alive:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{pane}: surviving owned processes {alive}; resources preserved")
        time.sleep(0.1)


def release_name(pane: str, current: Entity) -> None:
    # Process exit can precede Herdr's name release; retire only this stopped owner,
    # never a replacement client that appeared after the verified exit.
    for agent in herdr("agent", "list")["agents"]:
        if agent.get("pane_id") == pane and agent.get("name"):
            info = herdr("pane", "process-info", "--pane", pane)["process_info"]
            occupied = occupant(pane, info)[1]
            kind = agent.get("agent")
            # Herdr can clear kind before name. Only accept that gap at the shell,
            # after wait_for_exit verified the owned processes; snapshots are not atomic.
            if kind not in (None, current.get("agent")) or occupied:
                leader = info["foreground_process_group_id"]
                argv0 = next(
                    (
                        p.get("argv0", "unknown")
                        for p in info["foreground_processes"]
                        if p["pid"] == leader
                    ),
                    "unknown",
                )
                raise RuntimeError(
                    f"{pane}: owner changed during shutdown; preserved; "
                    f"previous_kind={current.get('agent')!r}, listed_kind={kind!r}, "
                    f"occupied={occupied}, leader_pid={leader}, leader_argv0={argv0!r}, "
                    f"shell_pid={info['shell_pid']}"
                )
            try:
                herdr("agent", "rename", pane, "--clear")
            except RuntimeError as error:
                try:
                    code = json.loads(str(error)).get("error", {}).get("code")
                except (ValueError, AttributeError) as decode_error:
                    raise error from decode_error
                if code != "agent_not_found":
                    raise
                # Herdr already released it between list and clear.


def live_workspaces() -> set[str]:
    return {w["workspace_id"] for w in herdr("workspace", "list")["workspaces"]}


def live_panes(workspace: str) -> list[Entity]:
    """The panes of a recorded workspace; none when Herdr no longer has it."""
    if not workspace or workspace not in live_workspaces():
        return []
    return herdr("pane", "list", "--workspace", workspace)["panes"]


def deliver(sends: list[tuple[str, str]]) -> list[str]:
    """Send every message; return the failed sends with their errors."""
    failed: list[str] = []
    for name, message in sends:
        try:
            herdr("agent", "prompt", name, message)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failed.append(f"{name}: {error}")
        else:
            print(f"Notified {name}")
    return failed
