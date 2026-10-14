#!/usr/bin/env python3
"""Manage brief teams in Herdr: start the pair, hand off the checkout, launch reviewers, stop.

Configured agents are `[agents.<entry>]` in config.toml. Each launch writes an allocation
record to `agent/teams/allocations/<slot>.json` with the record version, the allocation ID,
the implementer, merge-confirming tester, and every launched client's Herdr name, kind,
worktree, database suffix, port, pane, session and task-submission state. Restart, handoff
and teardown use that record. One lock on `agent/teams/allocations/.lock` serializes start,
review, reset and stop. Model, effort, advisor and persona come from
the current configuration. The brief's `Required reviews:` line names any additional reviewers.
"""

import contextlib
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from collections.abc import Generator, Sequence
from pathlib import Path
from typing import NotRequired, TypedDict, cast


class AgentSpec(TypedDict):
    role: str
    kind: str
    model: str
    effort: str
    advisor: NotRequired[str]
    persona: NotRequired[str]
    port_offset: int
    db_suffix: str


class TeamSettings(TypedDict):
    max_teams: int
    port_base: int
    port_stride: int
    postgres_port: int
    db_suffix_prefix: str


class Config(TypedDict):
    team: TeamSettings
    timeouts: dict[str, int]
    launch: dict[str, str]
    agents: dict[str, AgentSpec]


class Allocation(TypedDict):
    """One launched client. `pr` and `head` are set for reviewers of a pushed PR.

    `pane`, `name`, `kind`, `worktree` and `session` identify the client process.
    `submission` is the task-submission state, separate from whether a process runs:
    NEVER_SUBMITTED until launch writes UNKNOWN, durably, before the client can accept any
    input; SUBMITTED only after the task prompt's positive transport result. SUBMITTED does
    not mean the task is done; the brief, PR and reviews record its outcome.
    """

    entry: str
    role: str
    name: str
    kind: str
    worktree: str
    db_suffix: str
    port: int
    workspace: str
    tab: str
    pane: str
    session: str
    submission: str
    pr: NotRequired[str]
    head: NotRequired[str]


class Record(TypedDict):
    """A slot's allocation record: the brief, its roster, its Herdr workspace and tabs, and
    every launched client. `id` identifies this allocation; a slot number is reused."""

    version: int
    id: str
    slot: int
    brief: str
    worktree: str
    implementer: str
    tester: str
    workspace: str
    tabs: dict[str, str]
    agents: dict[str, Allocation]


class Process(TypedDict):
    pid: int
    cwd: str
    argv0: NotRequired[str]


class ProcessInfo(TypedDict):
    shell_pid: int
    foreground_process_group_id: int
    foreground_processes: list[Process]


# Herdr commands return different subsets. Callers access only the requested fields.
class Entity(TypedDict):
    pane_id: str
    tab_id: str
    workspace_id: str
    label: str
    name: str
    agent: str
    agent_status: str
    cwd: str
    foreground_cwd: str
    agent_session: dict[str, object]


class HerdrResult(TypedDict):
    pane: Entity
    root_pane: Entity
    workspace: Entity
    tab: Entity
    agent: Entity
    panes: list[Entity]
    workspaces: list[Entity]
    agents: list[Entity]
    process_info: ProcessInfo


ProcessRows = dict[int, tuple[int, str]]
ROLES = ("designer", "implementer", "tester")
# A team's workspace holds one tab per role; every client of that role is a pane in it.
TABS = {"designer": "designers", "implementer": "implementers", "tester": "reviewers"}
ENTRY = r"[a-z0-9][a-z0-9-]*"
RECORD_VERSION = 2
NEVER_SUBMITTED, UNKNOWN, SUBMITTED = "never_submitted", "unknown", "submitted"
AGENT_FIELDS = {"role", "kind", "model", "effort", "advisor", "persona", "port_offset", "db_suffix"}
# Dexter's query gives up this long after --wait: its allowance to reach the daemon.
DEXTER_CONNECT_SECONDS = 30
# A cold Hex cache downloads every package; anything slower is a hung fetch.
DEPS_FETCH_SECONDS = 300
CODEX_CONFIG = """[plugins."mix-credo@elixir-agent-tools"]
enabled = true
"""
# Disable alternate language paths in launched clients, without editing user settings.
NATIVE_LSP_PLUGINS = {
    "elixir-lsp@elixir-agent-tools": False,
}
main: Path
cfg: Config


def command_args(
    args: Sequence[str | Path | int],
    *,
    path: str | None = None,
    cwd: str | Path | None = None,
) -> list[str]:
    """Resolve the executable on PATH; keep every argument separate."""
    if not args:
        raise ValueError("Expected a nonempty command")
    command = list(map(str, args))
    directory = Path(cwd or Path.cwd()).resolve()
    search_path = os.environ.get("PATH", os.defpath) if path is None else path
    search_path = os.pathsep.join(str(directory / entry) for entry in search_path.split(os.pathsep))
    program = str(directory / command[0]) if os.path.dirname(command[0]) else command[0]
    executable = shutil.which(program, path=search_path)
    if executable is None:
        raise FileNotFoundError(f"Executable not found: {command[0]}")
    command[0] = executable
    return command


def execute(
    args: Sequence[str | Path | int],
    *,
    cwd: str | Path | None = None,
    env: dict[str, str] | None = None,
    timeout: float | None = None,
    check: bool = False,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run a resolved executable without a shell and capture its output."""
    # Reviewed S603: callers pass fixed tool names; command_args resolves argv[0], no shell.
    return subprocess.run(  # noqa: S603
        command_args(args, path=env.get("PATH", os.defpath) if env is not None else None, cwd=cwd),
        cwd=cwd,
        env=env,
        timeout=timeout,
        check=check,
        text=True,
        capture_output=True,
        input=input_text,
    )


def run(
    *args: str | Path | int,
    cwd: str | Path | None = None,
    timeout: float | None = None,
    env: dict[str, str] | None = None,
    input_text: str | None = None,
) -> str:
    p = execute(args, cwd=cwd, timeout=timeout, env=env, input_text=input_text)
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"Command failed: {args}")
    return p.stdout.strip()


def require_git_admin(common: Path) -> None:
    """Check write access to main's .git before running Git administration.

    Probe by creating a temporary file; mode bits may not reveal a sandbox write denial.
    """
    try:
        with tempfile.TemporaryFile(dir=common):
            pass
    except OSError as error:
        raise RuntimeError(
            f"Cannot write {common} ({error.strerror}); "
            "ask the dispatcher to run it from the main checkout."
        ) from error


def object_fields(value: object, label: str) -> dict[str, object]:
    """Validate external object keys before interpreting their values."""
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object; received {value!r}")
    fields = cast(dict[object, object], value)
    if not all(isinstance(key, str) for key in fields):
        raise ValueError(f"{label} must have string keys; received {value!r}")
    return cast(dict[str, object], fields)


def require_type(value: object, expected: type[str] | type[int], label: str) -> None:
    if type(value) is not expected:
        raise ValueError(f"{label} must be {expected.__name__}; received {value!r}")


def entity_fields(value: object, label: str) -> None:
    fields = object_fields(value, label)
    for key, annotation in Entity.__annotations__.items():
        if key in fields and fields[key] is not None:
            if annotation is str:
                require_type(fields[key], str, f"{label}.{key}")
            else:
                object_fields(fields[key], f"{label}.{key}")


def object_list(value: object, label: str) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list; received {value!r}")
    return [object_fields(item, label) for item in cast(list[object], value)]


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
    output = run("herdr", *args, timeout=cfg["timeouts"]["launch_seconds"])
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
    deadline = time.monotonic() + cfg["timeouts"]["shutdown_seconds"]
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


def load_config() -> tuple[Path, Config]:
    script = Path(__file__).resolve()
    common = Path(
        run("git", "-C", script.parent, "rev-parse", "--path-format=absolute", "--git-common-dir")
    )
    canonical = common.parent.resolve()
    path = Path(os.environ.get("TIPS_TEAM_CONFIG", canonical / "agent/teams/config.toml"))
    with path.open("rb") as f:
        value = cast(Config, tomllib.load(f))
    validate_config_fields(path, value)
    validate_settings(path, value)
    validate_allocations(path, value)
    return canonical, value


def validate_config_fields(path: Path, value: Config) -> None:
    fields = object_fields(value, str(path))
    settings = object_fields(fields.get("team"), f"{path}: team")
    for key in ("max_teams", "port_base", "port_stride", "postgres_port"):
        require_type(settings.get(key), int, f"{path}: team.{key}")
    require_type(settings.get("db_suffix_prefix"), str, f"{path}: team.db_suffix_prefix")
    object_fields(fields.get("timeouts"), f"{path}: timeouts")
    policies = object_fields(fields.get("launch"), f"{path}: launch")
    for key in ("codex_approval", "claude_permission_mode"):
        require_type(policies.get(key), str, f"{path}: launch.{key}")
    agents = object_fields(fields.get("agents"), f"{path}: agents")
    if not agents:
        raise RuntimeError(f"{path}: agents must name at least one entry")
    for name, entry in agents.items():
        validate_agent_fields(f"{path}: agents.{name}", name, entry)


def validate_agent_fields(label: str, name: str, entry: object) -> None:
    if not re.fullmatch(ENTRY, name):
        raise RuntimeError(f"{label} must match {ENTRY}")
    spec = object_fields(entry, label)
    unknown = set(spec) - AGENT_FIELDS
    if unknown:
        raise RuntimeError(f"{label} has unknown keys {sorted(unknown)}")
    for key in ("role", "kind", "model", "effort", "db_suffix"):
        require_type(spec.get(key), str, f"{label}.{key}")
    for key in ("advisor", "persona"):
        if key in spec:
            require_type(spec[key], str, f"{label}.{key}")
    require_type(spec.get("port_offset"), int, f"{label}.port_offset")


def validate_settings(path: Path, value: Config) -> None:
    for key in (
        "launch_seconds",
        "shutdown_seconds",
        "shell_seconds",
        "checks_minutes",
        "dexter_startup_seconds",
        "lock_seconds",
    ):
        if type(value["timeouts"][key]) is not int or value["timeouts"][key] <= 0:
            raise RuntimeError(f"{path}: timeouts.{key} must be a positive integer")
    if value["team"]["max_teams"] < 1:
        raise RuntimeError(f"{path}: team.max_teams must be positive")
    for name, spec in value["agents"].items():
        if spec["role"] not in ROLES:
            raise RuntimeError(f"{path}: agents.{name}.role must be one of {', '.join(ROLES)}")
        if spec["kind"] not in ("codex", "claude"):
            raise RuntimeError(f"{path}: agents.{name}.kind must be claude or codex")
        if spec.get("advisor") and spec["kind"] != "claude":
            raise RuntimeError(f"{path}: agents.{name}.advisor applies to Claude entries only")


def overlapping(a: str, b: str) -> bool:
    """Whether one database stem is the other or one of its numbered partitions."""
    return bool(
        re.fullmatch(re.escape(a) + r"[0-9]*", b) or re.fullmatch(re.escape(b) + r"[0-9]*", a)
    )


def validate_allocations(path: Path, value: Config) -> None:
    ports: set[int] = set()
    stems: list[str] = []
    for n in range(1, value["team"]["max_teams"] + 1):
        for spec in value["agents"].values():
            port = (
                value["team"]["port_base"] + n * value["team"]["port_stride"] + spec["port_offset"]
            )
            stem = value["team"]["db_suffix_prefix"] + str(n) + spec["db_suffix"]
            if port in ports or not 1 <= port <= 65535:
                raise RuntimeError(f"{path}: overlapping or invalid test ports")
            if any(overlapping(stem, other) for other in stems):
                raise RuntimeError(f"{path}: overlapping database suffix/partition allocation")
            ports.add(port)
            stems.append(stem)


def git(*args: str | Path, root: Path | None = None) -> str:
    return run("git", "-C", root or main, *args)


def records_dir() -> Path:
    return main / "agent/teams/allocations"


def record_path(slot: int) -> Path:
    return records_dir() / f"{slot}.json"


def require_current_record(path: Path, fields: dict[str, object]) -> None:
    """Refuse a record another team.py version wrote, or one without a valid allocation ID."""
    if "version" not in fields:
        raise RuntimeError(
            f"{path} was written by a team.py without record versions; refusing every launch "
            "and stop. Drain it with the team.py that wrote it, as agent/teams/SETUP.md "
            '"Records from an older team.py" says.'
        )
    if fields["version"] != RECORD_VERSION:
        raise RuntimeError(
            f"{path}: record version {fields['version']!r} is not {RECORD_VERSION}; preserved"
        )
    allocation_id = fields.get("id")
    if not isinstance(allocation_id, str) or not re.fullmatch(r"[0-9a-f]{32}", allocation_id):
        raise RuntimeError(f"{path}: allocation id must be 32 hex digits; preserved")


def load_record(path: Path) -> Record:
    """Read a record this version wrote. Never fill in a default for a missing field: a
    client that a default called never-submitted could do its task twice."""
    fields = object_fields(json.loads(path.read_text()), str(path))
    require_current_record(path, fields)
    require_type(fields.get("slot"), int, f"{path}: slot")
    for key in ("brief", "worktree", "implementer", "tester", "workspace"):
        require_type(fields.get(key), str, f"{path}: {key}")
    for label, tab in object_fields(fields.get("tabs"), f"{path}: tabs").items():
        require_type(tab, str, f"{path}: tabs.{label}")
    for entry, value in object_fields(fields.get("agents"), f"{path}: agents").items():
        allocation = object_fields(value, f"{path}: agents.{entry}")
        for key in (
            "entry",
            "role",
            "name",
            "kind",
            "worktree",
            "db_suffix",
            "workspace",
            "tab",
            "pane",
            "session",
        ):
            require_type(allocation.get(key), str, f"{path}: agents.{entry}.{key}")
        require_type(allocation.get("port"), int, f"{path}: agents.{entry}.port")
        if allocation.get("submission") not in (NEVER_SUBMITTED, UNKNOWN, SUBMITTED):
            raise RuntimeError(f"{path}: agents.{entry}.submission is not a known state; preserved")
    return cast(Record, fields)


def save_record(record: Record) -> None:
    """Replace the slot's record atomically and durably: once this returns, a launcher crash
    or timeout keeps the new record. The directory must be on a local filesystem."""
    path = record_path(record["slot"])
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = path.with_suffix(".json.tmp")
    with staged.open("w") as handle:
        handle.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    staged.replace(path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


@contextlib.contextmanager
def store_lock() -> Generator[None]:
    """Hold the record store's lock: one start, review, reset or stop at a time.

    The lock is on a file that is never replaced, so it is not lost when a record is
    rewritten. The kernel releases it when this process exits, even after a crash. Python
    opens files non-inheritable, so a child process never holds it.
    """
    path = records_dir() / ".lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    seconds = cfg["timeouts"]["lock_seconds"]
    with path.open("a") as handle:
        deadline = time.monotonic() + seconds
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"Busy: another team.py start, review, reset or stop held {path} for "
                        f"{seconds} s. Rerun this command after it finishes."
                    ) from None
                time.sleep(0.1)
        yield


def records() -> dict[int, Record]:
    """Every slot's allocation record; slot discovery reads these, not Herdr."""
    found: dict[int, Record] = {}
    if records_dir().is_dir():
        for path in sorted(records_dir().glob("*.json")):
            record = load_record(path)
            if path.stem != str(record["slot"]):
                raise RuntimeError(f"{path}: file name does not match slot {record['slot']}")
            found[record["slot"]] = record
    return found


def record_for(brief: str) -> Record | None:
    return next((r for r in records().values() if r["brief"] == brief), None)


def find_slot(brief: str) -> tuple[int, Record | None]:
    """The slot already holding this brief, else the first free one."""
    taken = records()
    for slot, record in taken.items():
        if record["brief"] == brief:
            return slot, record
    for slot in range(1, cfg["team"]["max_teams"] + 1):
        if slot not in taken:
            return slot, None
    raise RuntimeError(f"No free slot: team.max_teams is {cfg['team']['max_teams']}")


def live_name(slot: int, entry: str) -> str:
    return f"team-{slot}-{entry}"


def reserved() -> list[Allocation]:
    """Return saved allocations, even if the current configuration has changed."""
    return [a for record in records().values() for a in record["agents"].values()]


def reviewer_names(value: str) -> list[str]:
    """Return names from `Required reviews:`. Reject empty or duplicate names."""
    names = [name.strip() for name in value.split(",")]
    if not all(names) or len(set(names)) != len(names):
        raise ValueError("empty or repeated name in Required reviews")
    return names


def issue_line(body: str, label: str) -> str | None:
    match = re.search(rf"^{re.escape(label)}:[ \t]*(.*?)[ \t]*$", body, re.MULTILINE)
    return match.group(1) if match else None


def roster(brief: str) -> tuple[str, list[str], list[str]]:
    """Read the brief's implementer, testers and reviewing designers from configured entries.

    Read reviewer names from `Required reviews:`. Keep testers in the listed order;
    the first tester confirms the merge. Return testers and designers separately.
    """
    body = str(json.loads(run("gh", "issue", "view", brief, "--json", "body")).get("body") or "")
    implementer = issue_line(body, "Implementer")
    reviews = issue_line(body, "Required reviews")
    if implementer is None or reviews is None:
        raise RuntimeError(f"Brief #{brief} needs an Implementer: and a Required reviews: line")
    try:
        names = reviewer_names(reviews)
    except ValueError as error:
        raise RuntimeError(f"Brief #{brief}: {error}") from error
    for name in (implementer, *names):
        if name not in cfg["agents"]:
            raise RuntimeError(f"Brief #{brief} names {name!r}, which is not a configured entry")
    if cfg["agents"][implementer]["role"] != "implementer":
        raise RuntimeError(f"Brief #{brief}: Implementer {implementer} is not an implementer entry")
    if implementer in names:
        raise RuntimeError(f"Brief #{brief}: implementer {implementer} cannot review its own PR")
    by_role = {role: [n for n in names if cfg["agents"][n]["role"] == role] for role in ROLES}
    if by_role["implementer"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names implementer entries")
    if not by_role["tester"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names no tester")
    return implementer, by_role["tester"], by_role["designer"]


COMMENT_TYPES = (
    "PROPOSAL",
    "CRITIQUE",
    "QUESTION",
    "ANSWER",
    "AGREE",
    "FINDING",
    "BLOCKED",
    "DONE",
    "EVENT",
)
HEADER = re.compile(r"^(?P<type>[A-Z]+) (?P<role>\S+) (?P<name>\S+) (?P<session>\S+)$")


def comment_header(kind: str, role: str, name: str, session: str) -> str:
    """The attribution line `<TYPE> <role> <name> <session>`."""
    if kind not in COMMENT_TYPES:
        raise RuntimeError(f"Comment type must be one of {', '.join(COMMENT_TYPES)}")
    return f"{kind} {role} {name} {session or 'unknown'}"


def repository() -> str:
    return str(json.loads(run("gh", "repo", "view", "--json", "nameWithOwner"))["nameWithOwner"])


def issue_comments(issue: str) -> list[dict[str, object]]:
    """Return issue comments oldest first, with id, html_url, body and created_at fields."""
    output = run(
        "gh", "api", "--paginate", "--slurp", f"repos/{repository()}/issues/{issue}/comments"
    )
    pages = json.loads(output)
    if not isinstance(pages, list):
        raise RuntimeError(f"issue #{issue} comments: expected pages, received {pages!r}")
    return [
        c for page in cast(list[object], pages) for c in object_list(page, f"#{issue} comments")
    ]


def post_comment(issue: str, text: str) -> str:
    """If the same comment exists, return its URL. Otherwise, post it."""
    for comment in issue_comments(issue):
        if comment.get("body") == text:
            return str(comment["html_url"])
    return run("gh", "issue", "comment", issue, "--body-file", "-", input_text=text)


def event_role(allocation: Allocation) -> str:
    return allocation["role"].split()[-1]


def post_event(brief: str, allocation: Allocation, text: str) -> None:
    """Record a launch on the brief as the launched client, with its session ID.

    Usage reports match agent names to session logs through this EVENT. If posting fails
    after the launch succeeds, the error includes the command needed to record the EVENT.
    """
    header = comment_header(
        "EVENT", event_role(allocation), allocation["name"], allocation["session"]
    )
    try:
        url = post_comment(brief, f"{header}\n{text}")
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise RuntimeError(
            f"EVENT not recorded on #{brief}: {error}. Post it: agent/teams/board.py post "
            f"{brief} EVENT --as {event_role(allocation)} {allocation['name']} "
            f"{allocation['session'] or 'unknown'} <<< {shlex.quote(text)}"
        ) from error
    print(f"Recorded on #{brief}: {url}")


def bound_command(binary: Path, root: Path, sources: Path | str) -> str:
    """Build the worktree's Dexter wrapper with paths to the binary, root and Elixir sources."""
    return (
        "#!/bin/sh\n"
        f"export DEXTER_ELIXIR_LIB_ROOT={shlex.quote(str(sources))}\n"
        f"exec {shlex.quote(str(binary))} --root {shlex.quote(str(root))}"
        ' "$@"\n'
    )


def warm_up_query(startup_seconds: int) -> list[str]:
    """Return wrapper arguments that start the daemon and wait for its index."""
    return ["query", "workspace-symbols", "--raw", "--wait", f"{startup_seconds}s", "MixProject"]


def dexter_binary() -> Path:
    home = Path(os.environ.get("TIPS_DEXTER_HOME", str(main / "agent/lsp/dexter"))).resolve()
    binary = home / "vendor/dexter"
    if not os.access(binary, os.X_OK):
        raise RuntimeError(f"Missing executable: {binary}; run agent/lsp/dexter/build.sh.")
    return binary


def elixir_sources(cwd: Path) -> Path:
    """The Elixir standard-library sources Dexter indexes for this worktree."""
    version = run(
        "elixir", "--short-version", cwd=cwd, timeout=cfg["timeouts"]["dexter_startup_seconds"]
    )
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError(f"Unexpected Elixir version: {version!r}")
    explicit = os.environ.get("DEXTER_ELIXIR_LIB_ROOT")
    sources = (
        Path(explicit) if explicit else main / "agent/lsp/vendor" / f"elixir-{version}" / "lib"
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


def db_suffix(entry: str, slot: int) -> str:
    return cfg["team"]["db_suffix_prefix"] + str(slot) + cfg["agents"][entry]["db_suffix"]


def test_port(entry: str, slot: int) -> int:
    team = cfg["team"]
    return team["port_base"] + team["port_stride"] * slot + cfg["agents"][entry]["port_offset"]


def agent_env(allocation: Allocation) -> dict[str, str]:
    """Build the client's environment from its recorded database, port and worktree tools."""
    config = Path(os.environ.get("TIPS_TEAM_CONFIG", main / "agent/teams/config.toml")).resolve()
    worktree = Path(allocation["worktree"])
    env = {
        "PGPORT": str(cfg["team"]["postgres_port"]),
        "TIPS_DB_SUFFIX": allocation["db_suffix"],
        "TIPS_TEST_PORT": str(allocation["port"]),
        "MIX_ENV": "test",
        "TIPS_CHECK_TIMEOUT_SECONDS": str(cfg["timeouts"]["checks_minutes"] * 60),
        "TIPS_TEAM_CONFIG": str(config),
        # Provider settings are read by path from the main checkout; nothing is copied.
        "TIPS_PROVIDER_ENV_FILE": str(main / ".env"),
        "TIPS_DEXTER": str(worktree / ".dexter/dexter.sh"),
    }
    if allocation["kind"] == "codex":
        # Codex's sandbox cannot write the shared Hex cache in the home directory.
        env["HEX_HOME"] = str(worktree / "tmp/hex")
    return env


def allocate(record: Record, entry: str, role: str, worktree: Path) -> Allocation:
    """Reserve the entry's database and port in this slot and save them in its allocation record."""
    slot = record["slot"]
    suffix, port = db_suffix(entry, slot), test_port(entry, slot)
    for held in reserved():
        if overlapping(suffix, held["db_suffix"]) or port == held["port"]:
            raise RuntimeError(
                f"{entry}: database {suffix} or port {port} collides with {held['name']}'s "
                f"allocation ({held['db_suffix']}, {held['port']})"
            )
    allocation = Allocation(
        entry=entry,
        role=role,
        name=live_name(slot, entry),
        kind=cfg["agents"][entry]["kind"],
        worktree=str(worktree),
        db_suffix=suffix,
        port=port,
        workspace="",
        tab="",
        pane="",
        session="",
        submission=NEVER_SUBMITTED,
    )
    record["agents"][entry] = allocation
    return allocation


def checkout(worktree: Path, branch: str | None, commit: str | None) -> bool:
    """Add the worktree on `branch` from fetched origin/main, or detached at `commit`.

    Return whether it is new. An existing pair worktree is kept as it is: its agent may
    hold unfinished work. An existing reviewer worktree moves to `commit` when clean,
    so a relaunched reviewer sees the head its brief names.
    """
    git("fetch", "origin")
    if worktree.exists():
        if Path(git("rev-parse", "--show-toplevel", root=worktree)) != worktree or (
            branch and git("branch", "--show-current", root=worktree) != branch
        ):
            raise RuntimeError(f"Not the expected worktree: {worktree}")
        if commit and git("rev-parse", "HEAD", root=worktree) != commit:
            if git("status", "--porcelain", "--untracked-files=all", root=worktree):
                raise RuntimeError(f"{worktree} is dirty and not at {commit}; preserved")
            require_commit(commit)
            git("checkout", "--detach", "-q", commit, root=worktree)
        return False
    if branch:
        if git("branch", "--list", branch):
            git("worktree", "add", worktree, branch)
        else:
            git("worktree", "add", "--no-track", "-b", branch, worktree, "origin/main")
    else:
        require_commit(str(commit))
        git("worktree", "add", "--detach", worktree, str(commit))
    return True


def require_commit(commit: str) -> None:
    if execute(["git", "-C", main, "cat-file", "-e", f"{commit}^{{commit}}"]).returncode:
        raise RuntimeError(f"Commit {commit} is not on origin; push it first")


def link_skills(link: Path, shared: Path) -> None:
    if link.is_symlink() and os.readlink(link) == str(shared):
        return
    if link.exists() and not link.is_symlink():
        raise RuntimeError(f"Refusing to replace existing skills: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to(shared)


def prepare_index(worktree: Path, wrapper: Path, env: dict[str, str], fetch: bool) -> None:
    """Fetch a new checkout's locked dependencies, start Dexter and update its index."""
    if fetch:
        # --check-locked never rewrites the lock. A reused worktree keeps its own dependency
        # state: it may hold an unfinished change that only its agent can resolve.
        run(
            "mix",
            "deps.get",
            "--check-locked",
            cwd=worktree,
            env=env,
            timeout=DEPS_FETCH_SECONDS,
            input_text="",
        )
    # The query ends itself within --wait plus its connection allowance, so a valid slow
    # start is never cut short; the margin only catches a hung query.
    seconds = cfg["timeouts"]["dexter_startup_seconds"]
    budget = seconds + DEXTER_CONNECT_SECONDS + 5
    output = run(
        "/bin/sh", wrapper, *warm_up_query(seconds), env=env, timeout=budget, input_text=""
    )
    if not json.loads(output):
        raise RuntimeError("Dexter indexed no MixProject module; inspect the daemon log.")
    # A daemon that was already running does not watch deps/: reconcile it with the disk.
    run("/bin/sh", wrapper, "reindex", env=env, timeout=budget, input_text="")
    print(f"Dexter index ready for {worktree}")


def tools(worktree: Path) -> tuple[Path, Path, Path]:
    """Check the required tools before changing the worktree; return their paths."""
    binary, skills = dexter_binary(), main / ".agents/skills"
    if not skills.is_dir():
        raise RuntimeError("Shared skills directory is missing.")
    return binary, skills, elixir_sources(worktree if worktree.is_dir() else main)


def prepare_worktree(
    worktree: Path, clients: list[Allocation], branch: str | None, commit: str | None
) -> None:
    """Create or reuse a worktree and prepare it once for the clients that will use it."""
    binary, skills, sources = tools(worktree)
    new = checkout(worktree, branch, commit)
    wrapper = worktree / ".dexter/dexter.sh"
    files = {
        wrapper: bound_command(binary, worktree, sources),
        worktree / ".dexter/.gitignore": "*\n",
        worktree / ".codex/config.toml": CODEX_CONFIG,
    }
    for path, content in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_text() != content:
            path.write_text(content)
    wrapper.chmod(0o755)
    link_skills(worktree / ".agents/skills", skills)
    # A Codex client's environment wins: its sandbox needs the Hex cache inside the worktree.
    owner = next((c for c in clients if c["kind"] == "codex"), clients[0])
    env = {**os.environ, **agent_env(owner)}
    # A fetch that failed last time left no dependencies: fetch again.
    prepare_index(worktree, wrapper, env, fetch=new or not (worktree / "deps").is_dir())


def refuse_foreign_owner(worktree: Path, names: list[str]) -> None:
    """Only the assigned clients may work in a worktree."""
    for agent in herdr("agent", "list")["agents"]:
        if agent.get("name") not in names and pane_occupant(agent["pane_id"])[0] == worktree:
            owner = agent.get("name") or agent["pane_id"]
            raise RuntimeError(f"Conflicting live agent in {worktree}: {owner}")


def live_workspaces() -> set[str]:
    return {w["workspace_id"] for w in herdr("workspace", "list")["workspaces"]}


def live_panes(workspace: str) -> list[Entity]:
    """The panes of a recorded workspace; none when Herdr no longer has it."""
    if not workspace or workspace not in live_workspaces():
        return []
    return herdr("pane", "list", "--workspace", workspace)["panes"]


def open_pane(record: Record, allocation: Allocation) -> None:
    """Keep the client's recorded pane, or open one in its team's workspace and role tab.

    The team shares one workspace, labelled after its slot and brief. Each role has one
    tab; a second client of the role is a split of the tab's last pane.
    """
    label = TABS[cfg["agents"][allocation["entry"]]["role"]]
    panes = live_panes(record["workspace"])
    if allocation["pane"] in {p["pane_id"] for p in panes}:
        return
    if not panes:
        created = herdr(
            "workspace",
            "create",
            "--cwd",
            str(main),
            "--label",
            f"team-{record['slot']}-{record['brief']}",
            "--no-focus",
        )
        # The workspace exists now; a failure below must still find it.
        record["workspace"] = created["workspace"]["workspace_id"]
        record["tabs"] = {label: created["tab"]["tab_id"]}
        save_record(record)
        herdr("tab", "rename", created["tab"]["tab_id"], label)
        pane = created["root_pane"]
    else:
        tab = record["tabs"].get(label, "")
        siblings = [p for p in panes if p["tab_id"] == tab]
        if siblings:
            direction = "right" if len(siblings) == 1 else "down"
            pane = herdr(
                "pane",
                "split",
                siblings[-1]["pane_id"],
                "--direction",
                direction,
                "--cwd",
                str(main),
                "--no-focus",
            )["pane"]
        else:
            created = herdr(
                "tab",
                "create",
                "--workspace",
                record["workspace"],
                "--cwd",
                str(main),
                "--label",
                label,
                "--no-focus",
            )
            record["tabs"][label] = created["tab"]["tab_id"]
            pane = created["root_pane"]
    allocation["workspace"] = record["workspace"]
    allocation["tab"] = record["tabs"][label]
    allocation["pane"] = pane["pane_id"]
    save_record(record)
    herdr("pane", "rename", allocation["pane"], allocation["name"])


def enter(pane: str, worktree: Path, env: dict[str, str]) -> None:
    """Move the pane's shell into the worktree with the client's environment.

    The setup is typed into the pane, so it runs only when the pane is at its shell: typed
    into a client, it would be a prompt.
    """
    if pane_occupant(pane)[1]:
        raise RuntimeError(f"{pane}: a client appeared in the pane; preserved")
    token = uuid.uuid4().hex
    setup = (
        "cd -- "
        + shlex.quote(str(worktree))
        + " && export "
        + " ".join(shlex.quote(key + "=" + value) for key, value in env.items())
        # The format splits the marker, so neither the typed command's echo nor unwrapping,
        # which can drop spaces at a wrap point, acknowledges setup.
        + " && printf '\\nTIPS_PAIR_READY_%s\\n' "
        + token
    )
    herdr("pane", "run", pane, setup)
    herdr(
        "pane",
        "wait-output",
        pane,
        "--match",
        "TIPS_PAIR_READY_" + token,
        "--source",
        "recent-unwrapped",
        "--timeout",
        str(cfg["timeouts"]["shell_seconds"] * 1000),
    )


def dexter_brief(wrapper: Path) -> str:
    # The binary is shared by every checkout and the guide is not, so the binary's own
    # help defines the current syntax even when checkout docs are outdated.
    return (
        "Load the skills required by AGENTS.md before reading Elixir code. "
        "Follow its navigation table and function-use checks. "
        f"Run TIPS_DEXTER={wrapper} through the shell for this worktree. "
        'Read "$TIPS_DEXTER" query --help and "$TIPS_DEXTER" lookup --help once; '
        "Their syntax and output override outdated checkout docs. "
        'After fetching or changing dependencies, run "$TIPS_DEXTER" reindex. '
        "Do not start another Elixir language server. The index may be outdated; "
        "check empty results with rg. Leave the shared daemon running on exit. "
        "Do not run git clean -x; it deletes the wrapper and index."
    )


def identity(record: Record, entry: str, duty: str) -> str:
    persona = agent_spec(record["agents"][entry]).get("persona")
    text = f"You are {entry}, the {duty} for brief #{record['brief']}; your Herdr name is "
    text += f"{live_name(record['slot'], entry)}. "
    if persona:
        text += f"Your persona: {persona}. "
    return text


def pair_brief(record: Record, entry: str, duty: str, wrapper: Path) -> str:
    # A relaunched client gets this brief too, so it finds the turn instead of assuming it.
    implementer, tester = record["implementer"], record["tester"]
    partner = tester if entry == implementer else implementer
    return (
        identity(record, entry, duty)
        + f"Read agent/teams/README.md, then the brief with gh issue view {record['brief']}. "
        "Use the README restart rule to find whose turn it is. If yours, continue the "
        "workflow; otherwise end your turn and wait for your partner's message. "
        f"Hand the checkout over with agent/teams/team.py turn <pr> {partner}. "
        f"Put {entry}, <session> on line 2 of each review record; "
        "replace <session> with your session ID. " + dexter_brief(wrapper)
    )


def reviewer_brief(record: Record, entry: str, duty: str, pr: str, head: str, wrapper: Path) -> str:
    tester = live_name(record["slot"], record["tester"])
    return (
        identity(record, entry, duty)
        + f"Review PR {pr} from this worktree, pinned at {head}; never the pair checkout. "
        "Read agent/teams/README.md and follow its reviewer steps. Never run "
        "agent/teams/team.py turn. Submit the README review record with "
        f"{entry}, <session> on line 2; replace <session> with your session ID. "
        "Then notify the merge-confirming tester with "
        f"herdr agent prompt {tester} '<your review URL>' and end your turn. "
        "If the PR head changes, follow the README reviewer steps again. " + dexter_brief(wrapper)
    )


def agent_spec(allocation: Allocation) -> AgentSpec:
    """The entry's current model settings; its kind and resources stay as recorded."""
    spec = cfg["agents"].get(allocation["entry"])
    if spec is None:
        raise RuntimeError(f"{allocation['entry']} was removed from config.toml; restore it first")
    if spec["kind"] != allocation["kind"]:
        raise RuntimeError(f"{allocation['entry']} was launched as {allocation['kind']}; preserved")
    return spec


def client_args(allocation: Allocation, prompt: str) -> list[str]:
    """Client arguments. Claude keeps the brief as its system prompt and waits for its first
    message. Codex starts with no instructions: no tested signal shows that it accepted a
    task passed at start, so launch sends its brief as the first message."""
    spec, policies, worktree = agent_spec(allocation), cfg["launch"], allocation["worktree"]
    if spec["kind"] == "codex":
        args = ["-a", policies["codex_approval"], "-C", str(worktree)]
        if spec["model"]:
            args += ["-m", spec["model"]]
        return [*args, "-c", "model_reasoning_effort=" + json.dumps(spec["effort"])]
    args = [
        "--permission-mode",
        policies["claude_permission_mode"],
        "--effort",
        spec["effort"],
        # CLI settings also apply in linked worktrees and preserve user files.
        "--settings",
        json.dumps(
            {"enabledPlugins": {"mix-credo@elixir-agent-tools": True, **NATIVE_LSP_PLUGINS}}
        ),
        "--append-system-prompt",
        prompt,
    ]
    if spec["model"]:
        args += ["--model", spec["model"]]
    advisor = spec.get("advisor")
    if advisor:
        args += ["--advisor", advisor]
    return args


def running_client(record: Record, allocation: Allocation) -> Entity | None:
    """The recorded client if it is live in its pane; None if the pane is gone or at the shell.

    A live client with another name, kind or root makes the pane's owner uncertain: refused.
    """
    name, pane = allocation["name"], allocation["pane"]
    if pane not in {p["pane_id"] for p in live_panes(record["workspace"])}:
        return None
    root, live = pane_occupant(pane)
    if not live:
        return None
    agent = herdr("agent", "get", pane)["agent"]
    if agent.get("name") != name or agent.get("agent") != allocation["kind"]:
        raise RuntimeError(f"{pane}: conflicting client; preserved")
    if root != Path(allocation["worktree"]):
        raise RuntimeError(f"{pane}: {name} runs in {root}, not its worktree; preserved")
    return agent


def reconcile(record: Record, allocation: Allocation) -> Entity | None:
    """Return the live recorded client to adopt, or None when a launch may send the task.

    | Client | Submission | Result |
    |---|---|---|
    | live, recorded identity | unknown or submitted | adopt; resend nothing |
    | live, recorded identity | never submitted | refuse: this record did not start it |
    | another client in the pane | any | refuse |
    | none | never submitted | launch |
    | none | unknown or submitted | refuse: the client may have done the task, then exited |
    """
    agent = running_client(record, allocation)
    name, state = allocation["name"], allocation["submission"]
    if agent and state == NEVER_SUBMITTED:
        raise RuntimeError(
            f"{name} is live in {allocation['pane']}, but this record never started it; preserved"
        )
    if agent is None and state != NEVER_SUBMITTED:
        raise RuntimeError(
            f"{name} is not running and its task submission is {state}. It may have done the "
            "task before it exited, so nothing was launched or resent. Check its work on the "
            "brief and PR. To launch a replacement that gets the task again, run "
            f"agent/teams/team.py reset {record['brief']} {allocation['entry']}, then rerun "
            "this command."
        )
    return agent


def adopt(record: Record, allocation: Allocation, agent: Entity) -> None:
    """Keep a live recorded client. Record the session it reports; never resend its task."""
    name, session = allocation["name"], session_id(agent)
    if session and session != allocation["session"]:
        allocation["session"] = session
        save_record(record)
    if allocation["submission"] == SUBMITTED:
        return
    # The launch stopped before it finished; its EVENT may be missing. Posting is idempotent.
    post_event(record["brief"], allocation, launch_text(allocation))
    print(
        f"{name}: task submission is {allocation['submission']}; nothing was resent. If "
        f"{allocation['pane']} shows that the client never got its task, exit the client, run "
        f"agent/teams/team.py reset {record['brief']} {allocation['entry']}, then rerun this "
        "command."
    )


def launch_text(allocation: Allocation) -> str:
    return (
        f"launched {allocation['kind']} in {allocation['worktree']}; "
        f"database suffix {allocation['db_suffix']}; port {allocation['port']}"
    )


def launch(record: Record, allocation: Allocation, prompt: str) -> None:
    """Start one client in its pane and send its task, or adopt the one already there.

    The task-submission state is UNKNOWN on disk before the client starts: Claude's startup
    carries the brief, and a timeout cannot show what a client received. It becomes
    SUBMITTED only when Herdr reports that the task prompt was sent.
    """
    agent = reconcile(record, allocation)
    if agent:
        print(f"Already running: {allocation['name']} ({agent.get('agent_status')})")
        adopt(record, allocation, agent)
        return
    name, pane = allocation["name"], allocation["pane"]
    kind, worktree = allocation["kind"], Path(allocation["worktree"])
    args = client_args(allocation, prompt)  # a configuration error refuses before any change
    enter(pane, worktree, agent_env(allocation))
    allocation["submission"] = UNKNOWN
    save_record(record)
    herdr(
        "agent",
        "start",
        name,
        "--kind",
        kind,
        "--pane",
        pane,
        "--timeout",
        str(cfg["timeouts"]["launch_seconds"] * 1000),
        "--",
        *args,
    )
    started = herdr("agent", "get", pane)["agent"]
    allocation["session"] = session_id(started) or "unknown"
    save_record(record)
    if (
        pane_occupant(pane) != (worktree, True)
        or started.get("agent") != kind
        or started.get("name") != name
        or started.get("agent_status") in ("blocked", "unknown")
    ):
        raise RuntimeError(f"{name} started in an unexpected state or root; inspect {pane}")
    # The task prompt: Claude already holds its brief and waits for a first message.
    herdr("agent", "prompt", name, "Begin." if kind == "claude" else prompt)
    allocation["submission"] = SUBMITTED
    save_record(record)
    print(f"Launched {name}: {kind} in {worktree}, session {allocation['session']}")
    post_event(record["brief"], allocation, launch_text(allocation))


def require_main_checkout() -> None:
    if Path.cwd() != main:
        raise RuntimeError(f"Run from the main checkout: {main}")
    require_git_admin(main / ".git")


def current_roster(record: Record) -> tuple[list[str], list[str]]:
    """Read additional testers and designers from the brief; no separate list is stored.

    The pair owners are fixed in the record, so a brief that names another implementer
    or first tester is refused wherever it is read.
    """
    implementer, testers, designers = roster(record["brief"])
    if (implementer, testers[0]) != (record["implementer"], record["tester"]):
        raise RuntimeError(
            f"Brief #{record['brief']} changed its implementer or merge-confirming tester "
            "since launch; the pair checkout cannot change hands. Stop the brief after its "
            "work is merged, or restore the brief."
        )
    return testers[1:], designers


def start(brief: str) -> None:
    """Launch the brief's implementer and merge-confirming tester in one prepared worktree."""
    require_main_checkout()
    implementer, testers, _ = roster(brief)
    pair = [implementer, testers[0]]
    worktree = main / ".worktrees" / brief
    tools(worktree)  # missing tools refuse before a slot is reserved
    with store_lock():
        slot, record = find_slot(brief)
        if record is None:
            record = Record(
                version=RECORD_VERSION,
                id=uuid.uuid4().hex,
                slot=slot,
                brief=brief,
                worktree=str(worktree),
                implementer=pair[0],
                tester=pair[1],
                workspace="",
                tabs={},
                agents={},
            )
            save_record(record)  # the slot is reserved before anything is provisioned
        else:
            current_roster(record)
        refuse_foreign_owner(worktree, [live_name(slot, entry) for entry in pair])
        duties = ("implementer", "merge-confirming tester")
        clients = [
            record["agents"].get(entry) or allocate(record, entry, duty, worktree)
            for entry, duty in zip(pair, duties, strict=True)
        ]
        save_record(record)
        for allocation in clients:
            reconcile(record, allocation)  # refuse before preparing anything
        prepare_worktree(worktree, clients, f"task/{brief}", None)
        wrapper = worktree / ".dexter/dexter.sh"
        for allocation in clients:
            open_pane(record, allocation)
            prompt = pair_brief(record, allocation["entry"], allocation["role"], wrapper)
            launch(record, allocation, prompt)
    print(f"Brief {brief}: pair in slot {slot}, {worktree}")


def pull_request(pr: str) -> tuple[str, str, list[str]]:
    """The PR's URL, head commit and closing-reference issue numbers."""
    view = object_fields(
        json.loads(run("gh", "pr", "view", pr, "--json", "headRefOid,url,closingIssuesReferences")),
        f"PR {pr}",
    )
    references = object_list(view.get("closingIssuesReferences") or [], f"PR {pr} closing issues")
    briefs = [str(issue.get("number")) for issue in references]
    return str(view.get("url")), str(view.get("headRefOid")), briefs


def brief_record(pr: str, briefs: list[str]) -> Record:
    found = [r for brief in briefs if (r := record_for(brief))]
    if len(found) != 1:
        raise RuntimeError(f"PR {pr} must close exactly one started brief; closes {briefs}")
    return found[0]


def review(pr: str, entry: str) -> None:
    """Pin a required reviewer's own worktree at the PR head and launch it there."""
    require_main_checkout()
    url, head, briefs = pull_request(pr)
    with store_lock():
        record = brief_record(pr, briefs)
        testers, designers = current_roster(record)
        if entry not in testers + designers:
            raise RuntimeError(
                f"{entry} is not an additional reviewer of brief #{record['brief']} "
                f"(additional reviewers: {', '.join(testers + designers) or 'none'})"
            )
        duty = "reviewing designer" if entry in designers else "additional tester"
        worktree = main / ".worktrees" / f"review-{pr}-{entry}"
        refuse_foreign_owner(worktree, [live_name(record["slot"], entry)])
        allocation = record["agents"].get(entry) or allocate(record, entry, duty, worktree)
        allocation["pr"] = pr
        save_record(record)
        agent = reconcile(record, allocation)
        if agent:
            # A running reviewer keeps the head it is on; its record says which.
            allocation["head"] = git("rev-parse", "HEAD", root=worktree)
            save_record(record)
            print(f"Already running: {allocation['name']} at {allocation['head']}")
            adopt(record, allocation, agent)
            return
        prepare_worktree(worktree, [allocation], None, head)
        allocation["head"] = git("rev-parse", "HEAD", root=worktree)
        save_record(record)
        open_pane(record, allocation)
        wrapper = worktree / ".dexter/dexter.sh"
        prompt = reviewer_brief(record, entry, duty, url, allocation["head"], wrapper)
        launch(record, allocation, prompt)
    print(f"PR {pr}: {entry} reviews from {worktree} at {allocation['head']}")


def reset(brief: str, entry: str) -> None:
    """Record the operator's decision that a stopped client may be replaced with its task.

    Run it only after checking the brief and PR for what the client did. The client must
    not be running: a live one is adopted, never replaced.
    """
    require_main_checkout()
    with store_lock():
        record = record_for(brief)
        allocation = record["agents"].get(entry) if record else None
        if record is None or allocation is None:
            raise RuntimeError(f"Brief {brief} has no recorded client {entry}")
        if running_client(record, allocation):
            raise RuntimeError(
                f"{allocation['name']} is running in {allocation['pane']}; exit it first"
            )
        print(
            f"Reset {allocation['name']}: task submission was {allocation['submission']}, "
            f"session {allocation['session'] or 'none'}. The next start or review launches a "
            "replacement and sends its task."
        )
        allocation["submission"] = NEVER_SUBMITTED
        allocation["session"] = ""
        save_record(record)


def checkout_problem(head: str) -> str | None:
    """Why this checkout is not the pushed PR head, or None."""
    here = Path.cwd()
    if git("status", "--porcelain", "--untracked-files=all", root=here):
        return "The worktree has uncommitted or untracked files."
    local = git("rev-parse", "HEAD", root=here)
    if local != head:
        return f"HEAD is {local}, not the PR head {head}."
    return None


def caller_record() -> tuple[Record, str]:
    """The allocation record of the calling pane and the entry it runs."""
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane:
        raise RuntimeError("HERDR_PANE_ID is not set; run turn from your own pair pane")
    me = herdr("agent", "get", pane)["agent"].get("name") or ""
    for record in records().values():
        for entry, allocation in record["agents"].items():
            if me and allocation["name"] == me:
                return record, entry
    raise RuntimeError(f"This pane is {me or 'unnamed'}, not a launched client")


def tester_message(record: Record, pr: str, url: str, head: str) -> str:
    implementer, tester = record["implementer"], record["tester"]
    testers, designers = current_roster(record)
    others = testers + designers
    pending = [e for e in others if e not in record["agents"]]
    message = f"Your turn: review {url} at {head}."
    if pending:
        # Reviewer worktrees need Git administration, so the dispatcher provisions them.
        commands = "; ".join(f"agent/teams/team.py review {pr} {e}" for e in pending)
        message += (
            f" Before you review, ask the dispatcher to launch the other reviewers for "
            f"parallel review: herdr agent prompt dispatcher '{url} review: run {commands}'."
        )
    message += (
        " Follow agent/teams/roles/tester.md and agent/skills/review-software-correctness/SKILL.md "
        "from this worktree and use the README PR review record. "
        f"Put {tester}, <session> on line 2; replace <session> with your session ID. "
        f"If you find issues, submit your review and run "
        f"agent/teams/team.py turn {pr} {implementer}. "
        "If you find no issues, submit LGTM."
    )
    if others:
        named = ", ".join(f"{e} ({live_name(record['slot'], e)})" for e in others)
        message += (
            f" After your LGTM, read each required reviewer's latest review of this head: {named}. "
            f"If a review has findings, run agent/teams/team.py turn {pr} {implementer}. "
            "If a review is missing, notify that reviewer with the PR URL and head, or "
            "report blocked if they are not running. When every required reviewer's latest "
            "review of this head is LGTM, "
            "follow the README merge step: confirm all threads are resolved and required "
            "checks pass, then merge."
        )
    else:
        message += (
            " When your LGTM is the only required review, follow the README merge step: "
            "confirm all threads are resolved and required checks pass, then merge."
        )
    return (
        message + " After the merge, notify the dispatcher with "
        f"herdr agent prompt dispatcher '{url} done'."
    )


def implementer_message(pr: str, url: str, problem: str | None) -> str:
    message = (
        f"Your turn on {url}: run agent/teams/pr_review.py list {pr} and "
        f"gh pr checks {pr} --required. Fix review findings and failed checks following "
        "agent/skills/implement-software/SKILL.md from this worktree. Push your changes, "
        "then hand the turn back to the tester. If blocked, follow the README blocker procedure."
    )
    if problem:
        # Handing back never refuses: only the implementer can repair the checkout.
        message += f" Fix the checkout first: {problem}"
        print(f"Reported to the implementer: {problem}")
    return message


def turn(pr: str, recipient: str) -> None:
    """Transfer the turn to the other pair agent and notify it."""
    record, me = caller_record()
    pair = {record["implementer"], record["tester"]}
    if me not in pair or recipient not in pair or recipient == me:
        raise RuntimeError(
            f"turn hands the pair checkout between {record['implementer']} and "
            f"{record['tester']}; this pane is {me}"
        )
    if Path.cwd() != Path(record["worktree"]):
        raise RuntimeError(f"Run turn from the pair checkout: {record['worktree']}")
    url, head, briefs = pull_request(pr)
    if record["brief"] not in briefs:
        raise RuntimeError(
            f"PR {pr} does not close brief #{record['brief']} (closes {briefs or 'nothing'}); "
            "fix the PR's closing reference first"
        )
    problem = checkout_problem(head)
    if recipient == record["implementer"]:
        message = implementer_message(pr, url, problem)
    elif problem:
        raise RuntimeError(f"{problem} Commit and push, then hand over.")
    else:
        message = tester_message(record, pr, url, head)
    partner = live_name(record["slot"], recipient)
    herdr("agent", "prompt", partner, message)
    print(
        f"Notified {partner}. Stop using this worktree, build processes and files, "
        "and database; end your turn now."
    )


def stop_brief(brief: str) -> None:
    """Remove a brief's resources only when its work is clean and merged."""
    with store_lock():
        retire_brief(brief)


def retire_brief(brief: str) -> None:
    record = record_for(brief)
    if record is None:
        print(f"Brief {brief}: no allocation record; nothing removed")
        return
    live = {p["pane_id"] for p in live_panes(record["workspace"])}
    present = {e: a for e, a in record["agents"].items() if a["pane"] in live}
    require_only_recorded_panes(record)
    roots = owned_worktrees(present)
    pair = Path(record["worktree"])
    if pair.is_dir():
        roots.add(pair)
    recorded = {Path(a["worktree"]) for a in record["agents"].values()}
    roots |= {root for root in recorded if root.is_dir()}
    check_shared_owners(roots, present)
    if roots:
        require_git_admin(main / ".git")
        git("fetch", "origin")
    check_worktrees(roots)
    for allocation in present.values():
        stop(allocation["pane"], pane_occupant(allocation["pane"])[0])
    check_worktrees(roots)
    check_shared_owners(roots, present)
    # Rechecked at the close itself: a pane may have arrived during the shutdown.
    if require_only_recorded_panes(record):
        herdr("workspace", "close", record["workspace"])
    retire(roots, [a["db_suffix"] for a in record["agents"].values()])
    record_path(record["slot"]).unlink()
    print(f"Brief {brief}: slot {record['slot']} retired; main checkout status follows")
    print(git("status", "--short") or "Main checkout clean")


def require_only_recorded_panes(record: Record) -> bool:
    """Require every pane of the team's workspace to be recorded; closing the workspace
    closes them all. Return whether the workspace is live."""
    panes = live_panes(record["workspace"])
    recorded = {a["pane"] for a in record["agents"].values()}
    strangers = [p["pane_id"] for p in panes if p["pane_id"] not in recorded]
    if strangers:
        raise RuntimeError(
            f"Workspace of brief #{record['brief']} holds other panes {strangers}; preserved"
        )
    return bool(panes)


def retire(roots: set[Path], suffixes: list[str]) -> None:
    """Stop each worktree's daemon, drop the slot's databases, remove worktrees and branches."""
    for root in sorted(roots):
        wrapper = root / ".dexter/dexter.sh"
        if wrapper.is_file():
            result = execute(
                ["/bin/sh", wrapper, "stop"],
                timeout=cfg["timeouts"]["dexter_startup_seconds"],
                input_text="",
            )
            if result.returncode:
                raise RuntimeError(result.stderr or result.stdout)
    drop_databases(suffixes)
    for root in sorted(roots):
        branch = git("branch", "--show-current", root=root)
        git("worktree", "remove", root)
        # check_worktrees proved the branch merged into fetched origin/main; -d would
        # compare against the main checkout's own, possibly stale, branch.
        if branch.startswith("task/"):
            git("branch", "-D", branch)


def check_shared_owners(roots: set[Path], present: dict[str, Allocation]) -> None:
    """Do not remove a worktree used by an agent outside this slot."""
    owned_panes = {allocation["pane"] for allocation in present.values()}
    for agent in herdr("agent", "list")["agents"]:
        pane = agent["pane_id"]
        if pane not in owned_panes and pane_occupant(pane)[0] in roots:
            raise RuntimeError(f"Worktree still shared with {agent.get('name') or pane}; preserved")


def owned_worktrees(present: dict[str, Allocation]) -> set[Path]:
    roots: set[Path] = set()
    # Validate every pane before stopping any client.
    for allocation in present.values():
        pane = allocation["pane"]
        root = pane_occupant(pane)[0]
        if root != main and (
            root.parent != main / ".worktrees"
            or Path(
                git("rev-parse", "--path-format=absolute", "--git-common-dir", root=root)
            ).resolve()
            != main / ".git"
        ):
            raise RuntimeError(f"{pane}: unexpected worktree {root}; preserved")
        if pane_occupant(pane)[1]:
            agent = herdr("agent", "get", pane)["agent"]
            if agent.get("name") != allocation["name"]:
                raise RuntimeError(f"{pane}: conflicting owner; preserved")
        if root != main:
            roots.add(root)
    return roots


def check_worktrees(roots: set[Path]) -> None:
    for root in sorted(roots):
        if git("status", "--porcelain", "--untracked-files=all", root=root):
            raise RuntimeError(f"Dirty worktree {root}; remaining resources preserved")
        # Merged HEAD also proves all local commits reached origin/main.
        try:
            git("merge-base", "--is-ancestor", "HEAD", "origin/main", root=root)
        except RuntimeError as error:
            raise RuntimeError(
                f"Unmerged worktree {root}; remaining resources preserved"
            ) from error


def drop_databases(suffixes: list[str]) -> None:
    stems = [base + suffix for base in ("tips_test", "tips_dev") for suffix in suffixes]
    psql = [
        "docker",
        "compose",
        "exec",
        "-T",
        "db",
        "psql",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
    ]
    databases = run(*psql, "-Atc", "SELECT datname FROM pg_database", cwd=main).splitlines()
    for db in databases:
        if any(re.fullmatch(re.escape(stem) + r"[0-9]*", db) for stem in stems):
            # Do not use FORCE: an unexpected remaining connection blocks deletion.
            run(*psql, "-c", 'DROP DATABASE "' + db.replace('"', '""') + '"', cwd=main)


def configure() -> None:
    global main, cfg
    if os.environ.get("HERDR_ENV") != "1":
        raise RuntimeError("Run inside Herdr (HERDR_ENV=1)")
    main, cfg = load_config()


def stop_agent(pane: str, root: str | Path) -> None:
    """Stop the client gracefully; raise an error if its exit is uncertain.

    The caller must keep the checkout.
    """
    configure()
    stop(pane, root)


def cli() -> None:
    configure()
    args = sys.argv[1:]
    usage = (
        "Usage: agent/teams/team.py start <brief> | turn <pr> <entry> | "
        "review <pr> <entry> | reset <brief> <entry> | stop <brief>"
    )
    if len(args) < 2 or not args[1].isdecimal():
        raise RuntimeError(usage)
    named = len(args) == 3 and re.fullmatch(ENTRY, args[2]) is not None
    if args[0] == "start" and len(args) == 2:
        start(args[1])
    elif args[0] == "stop" and len(args) == 2:
        stop_brief(args[1])
    elif args[0] == "turn" and named:
        turn(args[1], args[2])
    elif args[0] == "review" and named:
        review(args[1], args[2])
    elif args[0] == "reset" and named:
        reset(args[1], args[2])
    else:
        raise RuntimeError(usage)


if __name__ == "__main__":
    try:
        cli()
    except (
        RuntimeError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"team: {error}", file=sys.stderr)
        sys.exit(1)
