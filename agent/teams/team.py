#!/usr/bin/env python3
"""Manage teams in Herdr: start a brief's pair, launch reviewers and designers, hand off, stop.

Configured agents are `[agents.<entry>]` in config.toml. Every client gets an allocation with
a generation ID that never repeats: an empty project directory it clones into itself with
bootstrap.py, a logs directory, and launcher configuration, all under the harness root
`~/.local/share/tips-agent-teams/<repo-key>/`. The slot's record in the root's `state/`
holds the record version and ID, the brief or spec, its roster, and every launched client's
Herdr name, kind, project, database suffix, port, pane, session and task-submission state.
Restart, handoff and retirement use that record. One lock on `state/.lock` serializes start,
design, review, reset and stop. This controller never runs Git, builds or a worker-provided
executable in a project.
"""

import contextlib
import errno
import fcntl
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import time
import uuid
from collections.abc import Generator, Sequence
from pathlib import Path
from typing import cast

import config as conf
from commands import execute, object_fields, object_list, require_type, run
from config import (
    COMMENT_TYPES,
    DATABASE_BASES,
    DISPATCHER_RECOVERY,
    ENTRY,
    HEADER,
    NAME_BYTES,
    NATIVE_LSP_PLUGINS,
    NEVER_SUBMITTED,
    PARTITION_DIGITS,
    READ_PAGES,
    READ_SECONDS,
    RECORD_VERSION,
    RETIREMENT,
    ROLES,
    SUBMITTED,
    TABS,
    UNKNOWN,
    Allocation,
    DispatcherLaunch,
    Entity,
    HerdrResult,
    ProcessInfo,
    ProcessRows,
    Record,
    Reports,
    agent_spec,
    allocation_paths,
    config_location,
    contained,
    database_stem,
    harness,
    live_name,
    overlapping,
    project_of,
    repository,
)

# --- Processes, JSON validation and Herdr ----------------------------------

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

# --- Records and allocations -----------------------------------------------

def record_path(slot: int) -> Path:
    return conf.state_dir() / f"{slot}.json"


def next_generation() -> int:
    """A generation this store never handed out before; call it under the lock."""
    path = conf.state_dir() / "generation"
    last = int(path.read_text()) if path.is_file() else 0
    staged = path.with_suffix(".tmp")
    staged.write_text(f"{last + 1}\n")
    staged.replace(path)
    return last + 1


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
    for key in ("slot", "generation"):
        require_type(fields.get(key), int, f"{path}: {key}")
    for key in ("kind", "brief", "implementer", "tester", "workspace"):
        require_type(fields.get(key), str, f"{path}: {key}")
    for label, tab in object_fields(fields.get("tabs"), f"{path}: tabs").items():
        require_type(tab, str, f"{path}: tabs.{label}")
    for entry, value in object_fields(fields.get("agents"), f"{path}: agents").items():
        allocation = object_fields(value, f"{path}: agents.{entry}")
        for key in (
            "id",
            "entry",
            "role",
            "name",
            "kind",
            "root",
            "db_suffix",
            "workspace",
            "tab",
            "pane",
            "session",
            "launch",
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
    """Hold the record store's lock: one start, design, review, reset or stop at a time.

    The lock is on a file that is never replaced, so it is not lost when a record is
    rewritten. The kernel releases it when this process exits, even after a crash. Python
    opens the file non-inheritable and `subprocess` closes other descriptors by default, so
    a child does not receive it.
    """
    path = conf.state_dir() / ".lock"
    seconds = conf.settings()["timeouts"]["lock_seconds"]
    with path.open("a") as handle:
        deadline = time.monotonic() + seconds
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"Busy: another team.py command held {path} for {seconds} s. "
                        "Rerun this command after it finishes."
                    ) from None
                time.sleep(0.1)
        yield


def records() -> dict[int, Record]:
    """Every slot's record; slot discovery reads these, not Herdr."""
    legacy = sorted((conf.main_checkout() / "agent/teams/allocations").glob("*.json"))
    if legacy:
        raise RuntimeError(
            f"{legacy[0]} was written by a team.py that used shared worktrees; refusing every "
            "launch and stop. Drain it with the team.py that wrote it, as agent/teams/SETUP.md "
            '"Records from an older team.py" says.'
        )
    found: dict[int, Record] = {}
    # Slot records are <slot>.json; other files there, such as dispatcher.json, are not.
    for path in sorted(p for p in conf.state_dir().glob("*.json") if p.stem.isdecimal()):
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
    for slot in range(1, conf.settings()["team"]["max_teams"] + 1):
        if slot not in taken:
            return slot, None
    raise RuntimeError(f"No free slot: team.max_teams is {conf.settings()['team']['max_teams']}")


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
    command = ["gh", "issue", "view", brief, *repo_args(), "--json", "body"]
    body = str(json.loads(github(command, deadline_from_now(), f"#{brief}")).get("body") or "")
    implementer = issue_line(body, "Implementer")
    reviews = issue_line(body, "Required reviews")
    if implementer is None or reviews is None:
        raise RuntimeError(f"Brief #{brief} needs an Implementer: and a Required reviews: line")
    try:
        names = reviewer_names(reviews)
    except ValueError as error:
        raise RuntimeError(f"Brief #{brief}: {error}") from error
    for name in (implementer, *names):
        if name not in conf.settings()["agents"]:
            raise RuntimeError(f"Brief #{brief} names {name!r}, which is not a configured entry")
    if conf.settings()["agents"][implementer]["role"] != "implementer":
        raise RuntimeError(f"Brief #{brief}: Implementer {implementer} is not an implementer entry")
    if implementer in names:
        raise RuntimeError(f"Brief #{brief}: implementer {implementer} cannot review its own PR")
    by_role = {
        role: [n for n in names if conf.settings()["agents"][n]["role"] == role] for role in ROLES
    }
    if by_role["implementer"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names implementer entries")
    if not by_role["tester"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names no tester")
    return implementer, by_role["tester"], by_role["designer"]


# --- GitHub comments -------------------------------------------------------

def comment_header(kind: str, role: str, name: str, session: str) -> str:
    """The attribution line `<TYPE> <role> <name> <session>`."""
    if kind not in COMMENT_TYPES:
        raise RuntimeError(f"Comment type must be one of {', '.join(COMMENT_TYPES)}")
    return f"{kind} {role} {name} {session or 'unknown'}"


def github(
    args: Sequence[str], deadline: float, label: str, input_text: str | None = None
) -> str:
    """Run one GitHub call within its whole operation's deadline; a late call is incomplete."""
    incomplete = f"{label}: incomplete after the {READ_SECONDS}s deadline"
    left = deadline - time.monotonic()
    if left <= 0:
        raise RuntimeError(incomplete)
    try:
        return run(*args, timeout=left, input_text=input_text)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(incomplete) from error


def deadline_from_now() -> float:
    return time.monotonic() + READ_SECONDS


def repo_args() -> list[str]:
    return ["--repo", repository()]


def issue_comments(issue: str, deadline: float | None = None) -> list[dict[str, object]]:
    """Return issue comments oldest first, with id, html_url, body and created_at fields.

    Deduplication and finding folds need every comment, so a truncated read raises.
    """
    deadline = deadline or deadline_from_now()
    path = f"repos/{repository(deadline)}/issues/{issue}/comments?per_page=100"
    found: list[dict[str, object]] = []
    for page in range(1, READ_PAGES + 1):
        output = github(["gh", "api", f"{path}&page={page}"], deadline, f"#{issue} comments")
        batch = object_list(json.loads(output), f"#{issue} comments")
        found += batch
        if len(batch) < 100:
            return found
    raise RuntimeError(f"#{issue} has over {READ_PAGES * 100} comments; read incomplete")


def post_comment(issue: str, text: str, deadline: float | None = None) -> str:
    """If the same comment exists, return its URL. Otherwise, post it. The read and the
    write share one deadline."""
    deadline = deadline or deadline_from_now()
    for comment in issue_comments(issue, deadline):
        if comment.get("body") == text:
            return str(comment["html_url"])
    return add_comment(issue, text, deadline)


def add_comment(issue: str, text: str, deadline: float) -> str:
    """Post a comment without a duplicate check; the caller has already read the issue."""
    command = ["gh", "issue", "comment", issue, *repo_args(), "--body-file", "-"]
    return github(command, deadline, f"comment on #{issue}", input_text=text)


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


# --- Tools and the client environment --------------------------------------

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


def test_port(entry: str, slot: int) -> int:
    team = conf.settings()["team"]
    return (
        team["port_base"]
        + team["port_stride"] * slot
        + conf.settings()["agents"][entry]["port_offset"]
    )


def agent_env(allocation: Allocation) -> dict[str, str]:
    """Build the client's environment from its recorded allocation."""
    config = config_location()[1].absolute()  # the file this command read
    project = project_of(allocation)
    env = {
        "PGPORT": str(conf.settings()["team"]["postgres_port"]),
        "TIPS_DB_SUFFIX": allocation["db_suffix"],
        "TIPS_TEST_PORT": str(allocation["port"]),
        "MIX_ENV": "test",
        "TIPS_CHECK_TIMEOUT_SECONDS": str(conf.settings()["timeouts"]["checks_minutes"] * 60),
        "TIPS_TEAM_CONFIG": str(config),
        # Provider settings are read by path from the main checkout; nothing is copied.
        "TIPS_PROVIDER_ENV_FILE": str(conf.main_checkout() / ".env"),
        "TIPS_DEXTER": str(project / ".dexter/dexter.sh"),
        # Worker-side commands resolve the same root, as PR5's install layout defines it.
        "TIPS_TEAM_HARNESS": str(conf.harness_root() / "harness"),
        "TIPS_TEAM_ALLOCATION_ID": allocation["id"],
        "TIPS_TEAM_LAUNCH": allocation["launch"],
        "TIPS_TEAM_STATE": str(conf.state_dir()),
    }
    if allocation["kind"] == "codex":
        # Codex's sandbox cannot write the shared Hex cache in the home directory.
        env["HEX_HOME"] = str(project / "tmp/hex")
    return env


def tools() -> tuple[Path, Path, Path]:
    """Check the shared tools before reserving anything; return the Dexter binary, the
    shared skills and the Elixir sources."""
    binary, skills = dexter_binary(), conf.main_checkout() / ".agents/skills"
    if not skills.is_dir():
        raise RuntimeError("Shared skills directory is missing.")
    return binary, skills, elixir_sources(conf.main_checkout())


def allocate(record: Record, entry: str, role: str) -> Allocation:
    """Reserve the entry's database and port, and create its allocation directory with an
    empty project and logs, and its launcher configuration directory, under the trusted
    root."""
    slot, generation = record["slot"], record["generation"]
    suffix = database_stem(
        conf.settings()["team"], slot, generation, conf.settings()["agents"][entry]["db_suffix"]
    )
    port = test_port(entry, slot)
    for held in reserved():
        if overlapping(suffix, held["db_suffix"]) or port == held["port"]:
            raise RuntimeError(
                f"{entry}: database {suffix} or port {port} collides with {held['name']}'s "
                f"allocation ({held['db_suffix']}, {held['port']})"
            )
    if len((max(DATABASE_BASES, key=len) + suffix).encode()) + PARTITION_DIGITS > NAME_BYTES:
        raise RuntimeError(f"{entry}: database names for {suffix} exceed {NAME_BYTES} bytes")
    ident = f"g{generation}-{entry}"
    root = conf.harness_root()
    for directory in allocation_paths(ident):
        # Checked before creation too: a symlinked parent would put the new directory
        # outside the root before the check after it could refuse.
        contained(directory, root)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        contained(directory, root)
    allocation = Allocation(
        id=ident,
        entry=entry,
        role=role,
        name=live_name(slot, entry),
        kind=conf.settings()["agents"][entry]["kind"],
        root=str(allocation_paths(ident)[0]),
        db_suffix=suffix,
        port=port,
        workspace="",
        tab="",
        pane="",
        session="",
        launch="",
        submission=NEVER_SUBMITTED,
    )
    record["agents"][entry] = allocation
    return allocation


def earlier_launch(record: Record, entry: str) -> list[str]:
    """What remains of an earlier launch of this client that no record holds.

    A missing record or entry never proves that a task was never sent: the record may have
    been lost while an allocation, workspace or client remained. Database names carry the
    generation, so an earlier launch's databases belong to an allocation found here.
    """
    held = {a["id"] for r in [*records().values(), record] for a in r["agents"].values()}
    found: list[str] = []
    for path in sorted(conf.state_dir().glob("*/bootstrap.json")):
        settings = object_fields(json.loads(path.read_text()), str(path))
        if (
            (settings.get("issue"), settings.get("entry")) == (record["brief"], entry)
            and path.parent.name not in held
            and not (path.parent / "retired.json").exists()
        ):
            found.append(f"allocation {path.parent.name}")
    label = re.compile(rf"team-[0-9]+-{re.escape(record['brief'])}")
    found += [
        f"Herdr workspace {w['label']}"
        for w in herdr("workspace", "list")["workspaces"]
        if label.fullmatch(w.get("label", "")) and w["workspace_id"] != record["workspace"]
    ]
    name = live_name(record["slot"], entry)
    if any(a.get("name") == name for a in herdr("agent", "list")["agents"]):
        found.append(f"Herdr client {name}")
    return found


def add_allocation(record: Record, entry: str, role: str) -> Allocation:
    """Allocate a client the record does not hold. If an earlier launch left anything
    behind, its task may already have been sent: record the submission as unknown."""
    remains = earlier_launch(record, entry)
    allocation = allocate(record, entry, role)
    if remains:
        allocation["submission"] = UNKNOWN
        print(
            f"{allocation['name']} has no earlier record, but these remain: "
            f"{', '.join(remains)}. Its task submission is recorded as unknown."
        )
    return allocation


def configure_bootstrap(record: Record, allocation: Allocation, branch: str, commit: str) -> None:
    """Write the launcher configuration bootstrap.py reads: what to clone and check out, the
    shared tools."""
    binary, skills, sources = tools()
    _, project, logs, config = allocation_paths(allocation["id"])
    settings = {
        "id": allocation["id"],
        "issue": record["brief"],
        "entry": allocation["entry"],
        "kind": allocation["kind"],
        "project": str(project),
        "logs": str(logs),
        "clone_url": conf.settings()["team"]["clone_url"],
        "repository": conf.settings()["github"]["repository"],
        "startup_seconds": conf.settings()["timeouts"]["dexter_startup_seconds"],
        "branch": branch,
        "commit": commit,
        "dexter": str(binary),
        "sources": str(sources),
        "skills": str(skills),
        # What the launch lets the worker write; bootstrap refuses trusted paths inside it.
        "writable": [allocation["root"]],
    }
    staged = config / "bootstrap.json.tmp"
    staged.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    staged.replace(config / "bootstrap.json")


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def refuse_foreign_owner(
    roots: list[Path], names: list[str], recorded: frozenset[str] = frozenset()
) -> None:
    """Only the assigned clients may work in their allocations.

    Herdr keeps listing a just-stopped client as an unnamed agent for a while (#451). That
    stale entry is skipped only in a recorded pane whose shell again leads the foreground,
    so no client process runs there; any other live agent is still refused.
    """
    for agent in herdr("agent", "list")["agents"]:
        pane = agent["pane_id"]
        cwd, occupied = pane_occupant(pane)
        if pane in recorded and not agent.get("name") and not occupied:
            continue
        for root in roots:
            if agent.get("name") not in names and inside(cwd, root):
                owner = agent.get("name") or agent["pane_id"]
                raise RuntimeError(f"Conflicting live agent in {root}: {owner}; preserved")


# --- Launch: panes, briefs, clients and recovery ---------------------------

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
    label = TABS[conf.settings()["agents"][allocation["entry"]]["role"]]
    panes = live_panes(record["workspace"])
    if allocation["pane"] in {p["pane_id"] for p in panes}:
        return
    if not panes:
        created = herdr(
            "workspace",
            "create",
            "--cwd",
            allocation["root"],
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
                allocation["root"],
                "--no-focus",
            )["pane"]
        else:
            created = herdr(
                "tab",
                "create",
                "--workspace",
                record["workspace"],
                "--cwd",
                allocation["root"],
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


def enter(pane: str, root: Path, env: dict[str, str]) -> None:
    """Move the pane's shell into the allocation directory with the client's environment.

    The setup is typed into the pane, so it runs only when the pane is at its shell: typed
    into a client, it would be a prompt.
    """
    if pane_occupant(pane)[1]:
        raise RuntimeError(f"{pane}: a client appeared in the pane; preserved")
    token = uuid.uuid4().hex
    setup = (
        "cd -- "
        + shlex.quote(str(root))
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
        str(conf.settings()["timeouts"]["shell_seconds"] * 1000),
    )


def bootstrap_brief(allocation: Allocation, commit: str) -> str:
    """The first task: the worker prepares its own project. Startup loaded no repository
    instructions: the client starts in the allocation directory, outside the clone."""
    _, project, logs, _ = allocation_paths(allocation["id"])
    command = f"python3 {harness() / 'bootstrap.py'}" + (f" --commit {commit}" if commit else "")
    return (
        f"Your allocation is {allocation['id']}; your project is {project}. First run "
        f"{command}: it clones the repository into the project or reuses your clone, fetches "
        "dependencies and starts Dexter. Its full log is in "
        f"{logs}. If it fails, report blocked with its error and stop; do not prepare the "
        f"project another way. Then work only in {project}: read its AGENTS.md and "
        "agent/teams/README.md; they were not loaded at startup. "
    )


def dexter_brief(wrapper: Path) -> str:
    # The binary is shared by every checkout and the guide is not, so the binary's own
    # help defines the current syntax even when checkout docs are outdated.
    return (
        "Load the skills required by AGENTS.md from .agents/skills before reading Elixir code. "
        "Follow its navigation table and function-use checks. "
        f"Run TIPS_DEXTER={wrapper} through the shell for this project. "
        'Read "$TIPS_DEXTER" query --help and "$TIPS_DEXTER" lookup --help once; '
        "Their syntax and output override outdated checkout docs. "
        'After fetching or changing dependencies, run "$TIPS_DEXTER" reindex. '
        "Do not start another Elixir language server. The index may be outdated; "
        "check empty results with rg. Leave the daemon running on exit. "
        "Do not run git clean -x; it deletes the wrapper and index. When the dispatcher asks "
        f"you to retire, run python3 {harness() / 'retirement.py'} and end your turn: it "
        "posts your clone's state to the issue, tells the dispatcher and changes nothing."
    )


def identity(record: Record, entry: str, duty: str) -> str:
    persona = agent_spec(record["agents"][entry]).get("persona")
    issue = "spec" if record["kind"] == "design" else "brief"
    text = f"You are {entry}, the {duty} for {issue} #{record['brief']}; your Herdr name is "
    text += f"{live_name(record['slot'], entry)}. "
    if persona:
        text += f"Your persona: {persona}. "
    return text


def pair_brief(record: Record, entry: str, duty: str) -> str:
    # A relaunched client gets this brief too, so it finds the turn instead of assuming it.
    allocation = record["agents"][entry]
    implementer, tester = record["implementer"], record["tester"]
    if entry == implementer:
        handoff = f"After each push, hand the head to the reviewers with {turn_command(tester)}. "
    else:
        handoff = f"Hand findings to the implementer with {turn_command(implementer)}. "
    return (
        identity(record, entry, duty)
        + bootstrap_brief(allocation, "")
        + f"Then read the brief with gh issue view {record['brief']}. Use the README restart "
        "rule to find whose turn it is. If yours, continue the workflow; otherwise end your "
        "turn and wait for a message. "
        + handoff
        + f"Put {entry}, <session> on line 2 of each review record; replace <session> with "
        "your session ID. "
        + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def turn_command(recipient: str) -> str:
    return f"python3 {harness() / 'team.py'} turn <pr> {recipient}"


def reviewer_brief(record: Record, entry: str, duty: str, pr: str, head: str) -> str:
    allocation = record["agents"][entry]
    tester = live_name(record["slot"], record["tester"])
    return (
        identity(record, entry, duty)
        + bootstrap_brief(allocation, head)
        + f"Review PR {pr} at {head} from your own clone. Follow the README reviewer steps. "
        "Never run team.py turn. Submit the README review record with "
        f"{entry}, <session> on line 2; replace <session> with your session ID. "
        "Then notify the merge-confirming tester with "
        f"herdr agent prompt {tester} '<your review URL>' and end your turn. "
        "When notified of a new head, the notice names the bootstrap command that moves "
        "your clone to it. "
        + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def design_brief(record: Record, entry: str) -> str:
    allocation = record["agents"][entry]
    return (
        identity(record, entry, "designer")
        + bootstrap_brief(allocation, "")
        + "Read agent/teams/roles/designer.md, then the spec with "
        f"gh issue view {record['brief']}; its body names the lead and the critics. Use "
        "agent/teams/board.py to read and post. "
        + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def client_args(allocation: Allocation, prompt: str, session: str) -> list[str]:
    """Client arguments. Claude keeps the brief as its system prompt and waits for its first
    message; it runs the session id the launcher assigned, because Herdr learns session ids
    from a user hook that restricted mode ignores. Codex starts with no instructions: no
    documented signal shows that it accepted a task passed at start, so launch sends its
    brief as the first message. Both start in the allocation directory, which holds the
    project and its logs."""
    spec, policies = agent_spec(allocation), conf.settings()["launch"]
    if spec["kind"] == "codex":
        args = ["-a", policies["codex_approval"], "-C", allocation["root"]]
        if spec["model"]:
            args += ["-m", spec["model"]]
        effort = ["-c", "model_reasoning_effort=" + json.dumps(spec["effort"])]
        return [*args, *effort]
    args = [
        "--permission-mode",
        policies["claude_permission_mode"],
        "--effort",
        spec["effort"],
        "--settings",
        json.dumps(
            {"enabledPlugins": {"mix-credo@elixir-agent-tools": True, **NATIVE_LSP_PLUGINS}}
        ),
        "--append-system-prompt",
        prompt,
        "--session-id",
        session,
    ]
    if spec["model"]:
        args += ["--model", spec["model"]]
    advisor = spec.get("advisor")
    if advisor:
        args += ["--advisor", advisor]
    return args


def running_client(record: Record, allocation: Allocation) -> Entity | None:
    """The recorded client if it is live in its pane; None if the pane is gone or at the shell.

    A live client with another name, kind, root or session makes the pane's owner
    uncertain: refused, and so is one that reports no session, since nothing then shows
    which client is live. Only a record with no session yet accepts the live one's.
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
    if root != Path(allocation["root"]):
        raise RuntimeError(f"{pane}: {name} runs in {root}, not its allocation; preserved")
    recorded, live_session = allocation["session"], session_id(agent)
    if not live_session:
        raise RuntimeError(
            f"{pane}: {name} reports no session; cannot confirm the recorded client; preserved. "
            "Nothing was resent; only the operator decides what happens to it."
        )
    if recorded not in ("", "unknown") and live_session != recorded:
        raise RuntimeError(f"{pane}: {name} runs session {live_session}, not {recorded}; preserved")
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
            "task before it exited, so nothing was launched or resent; only the operator "
            "decides whether to replay it: after checking its work on the brief and PR, the "
            f"operator runs python3 {harness() / 'team.py'} reset {record['brief']} "
            f"{allocation['entry']}, then reruns this command."
        )
    return agent


def adopt(record: Record, allocation: Allocation, agent: Entity) -> None:
    """Keep a live recorded client; never resend its task. If the launch stopped before the
    record held a session, record the one the client reports; running_client refused any
    other mismatch."""
    name, session = allocation["name"], session_id(agent)
    if session and allocation["session"] in ("", "unknown"):
        allocation["session"] = session
        save_record(record)
    if allocation["submission"] == SUBMITTED:
        return
    # The launch stopped before it finished; its EVENT may be missing. Posting is idempotent.
    post_event(record["brief"], allocation, launch_text(allocation))
    print(
        f"{name}: task submission is {allocation['submission']}; nothing was resent. Only the "
        f"operator decides whether to replay it: if {allocation['pane']} shows that the client "
        "never got its task, the operator exits the client, runs "
        f"python3 {harness() / 'team.py'} reset {record['brief']} {allocation['entry']} and "
        "reruns this command."
    )


def launch_text(allocation: Allocation) -> str:
    return (
        f"launched {allocation['kind']} in {allocation['root']}; allocation "
        f"{allocation['id']}; database suffix {allocation['db_suffix']}; port {allocation['port']}"
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
    kind, root = allocation["kind"], Path(allocation["root"])
    # Claude runs a session id assigned here; Codex's is known only if Herdr reports it.
    session = str(uuid.uuid4()) if kind == "claude" else ""
    args = client_args(allocation, prompt, session)  # a configuration error refuses first
    allocation["launch"] = uuid.uuid4().hex
    enter(pane, root, agent_env(allocation))
    allocation["submission"], allocation["session"] = UNKNOWN, session
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
        str(conf.settings()["timeouts"]["launch_seconds"] * 1000),
        "--",
        *args,
    )
    started = herdr("agent", "get", pane)["agent"]
    reported = session_id(started)
    if not session:
        allocation["session"] = reported or "unknown"
        save_record(record)
    if (
        pane_occupant(pane) != (root, True)
        or started.get("agent") != kind
        or started.get("name") != name
        or started.get("agent_status") in ("blocked", "unknown")
        or (session and reported not in ("", session))
    ):
        raise RuntimeError(f"{name} started in an unexpected state or root; inspect {pane}")
    # The task prompt: Claude already holds its brief and waits for a first message.
    herdr("agent", "prompt", name, "Begin." if kind == "claude" else prompt)
    allocation["submission"] = SUBMITTED
    save_record(record)
    print(f"Launched {name}: {kind} in {root}, session {allocation['session']}")
    post_event(record["brief"], allocation, launch_text(allocation))


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


def team_record(issue: str, kind: str, implementer: str, tester: str) -> Record:
    """The slot holding this issue, or a new record with a new generation in a free slot.

    Call under the lock. The record is saved before anything is created, so a failure
    later leaves a reservation that stop can retire.
    """
    slot, record = find_slot(issue)
    if record is not None:
        if record["kind"] != kind:
            raise RuntimeError(f"#{issue} already holds a {record['kind']} team in slot {slot}")
        return record
    record = Record(
        version=RECORD_VERSION,
        id=uuid.uuid4().hex,
        slot=slot,
        generation=next_generation(),
        kind=kind,
        brief=issue,
        implementer=implementer,
        tester=tester,
        workspace="",
        tabs={},
        agents={},
    )
    save_record(record)
    return record


def start(brief: str) -> None:
    """Launch the brief's implementer and merge-confirming tester, each in its own empty
    allocation; each clones and prepares its project itself."""
    implementer, testers, _ = roster(brief)
    pair = [implementer, testers[0]]
    tools()  # missing tools refuse before a slot is reserved
    with store_lock():
        record = team_record(brief, "brief", *pair)
        if record["implementer"]:
            current_roster(record)
        duties = ("implementer", "merge-confirming tester")
        for entry, duty in zip(pair, duties, strict=True):
            if entry not in record["agents"]:
                allocation = add_allocation(record, entry, duty)
                branch = f"task/{brief}" if entry == implementer else ""
                configure_bootstrap(record, allocation, branch, "")
                save_record(record)
        clients = [record["agents"][entry] for entry in pair]
        refuse_foreign_owner([Path(a["root"]) for a in clients], [a["name"] for a in clients])
        for allocation in clients:
            reconcile(record, allocation)  # refuse before opening anything
        for allocation in clients:
            open_pane(record, allocation)
            launch(record, allocation, pair_brief(record, allocation["entry"], allocation["role"]))
    print(f"Brief {brief}: pair in slot {record['slot']}, generation {record['generation']}")


def design(spec: str, entry: str) -> None:
    """Launch a designer for the spec in its own allocation, through the same lifecycle."""
    agent = conf.settings()["agents"].get(entry)
    if agent is None or agent["role"] != "designer":
        raise RuntimeError(f"{entry} is not a configured designer entry")
    tools()
    with store_lock():
        record = team_record(spec, "design", "", "")
        if entry not in record["agents"]:
            configure_bootstrap(record, add_allocation(record, entry, "designer"), "", "")
            save_record(record)
        allocation = record["agents"][entry]
        refuse_foreign_owner([Path(allocation["root"])], [allocation["name"]])
        open_pane(record, allocation)
        launch(record, allocation, design_brief(record, entry))
    print(f"Spec {spec}: {entry} in slot {record['slot']}, {allocation['root']}")


def pull_request(pr: str) -> tuple[str, str, list[str]]:
    """The PR's URL, head commit and closing-reference issue numbers."""
    fields = "headRefOid,url,closingIssuesReferences"
    command = ["gh", "pr", "view", pr, *repo_args(), "--json", fields]
    view = object_fields(json.loads(github(command, deadline_from_now(), f"PR {pr}")), f"PR {pr}")
    references = object_list(view.get("closingIssuesReferences") or [], f"PR {pr} closing issues")
    briefs = [str(issue.get("number")) for issue in references]
    return str(view.get("url")), str(view.get("headRefOid")), briefs


def brief_record(pr: str, briefs: list[str]) -> Record:
    found = [r for brief in briefs if (r := record_for(brief))]
    if len(found) != 1:
        raise RuntimeError(f"PR {pr} must close exactly one started brief; closes {briefs}")
    return found[0]


def review(pr: str, entry: str) -> None:
    """Launch a required reviewer in its own allocation, configured for the PR head."""
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
        allocation = record["agents"].get(entry) or add_allocation(record, entry, duty)
        allocation["pr"] = pr
        save_record(record)
        refuse_foreign_owner([Path(allocation["root"])], [allocation["name"]])
        agent = reconcile(record, allocation)
        if agent:
            # A running reviewer keeps the head it was given; new heads reach it by notice.
            print(f"Already running: {allocation['name']} at {allocation.get('head')}")
            adopt(record, allocation, agent)
            return
        allocation["pr"], allocation["head"] = pr, head
        configure_bootstrap(record, allocation, "", head)
        save_record(record)
        open_pane(record, allocation)
        launch(record, allocation, reviewer_brief(record, entry, duty, url, head))
    print(f"PR {pr}: {entry} reviews {head} from {project_of(allocation)}")


def reset(brief: str, entry: str) -> None:
    """Record the operator's decision that a stopped client may be replaced with its task.

    Run it only after checking the brief and PR for what the client did. The client must
    not be running: a live one is adopted, never replaced.
    """
    with store_lock():
        record = record_for(brief)
        allocation = record["agents"].get(entry) if record else None
        if record is None or allocation is None:
            raise RuntimeError(f"#{brief} has no recorded client {entry}")
        if running_client(record, allocation):
            raise RuntimeError(
                f"{allocation['name']} is running in {allocation['pane']}; exit it first"
            )
        print(
            f"Reset {allocation['name']}: task submission was {allocation['submission']}, "
            f"session {allocation['session'] or 'none'}. The next start, design or review "
            "launches a replacement in the same allocation and sends its task."
        )
        allocation["submission"] = NEVER_SUBMITTED
        allocation["session"] = ""
        save_record(record)


# --- Handoff and turns -----------------------------------------------------

def checkout_problem(project: Path, head: str) -> str | None:
    """Why the caller's own clone is not the pushed PR head, or None. Runs only from the
    worker's own turn, under its authority."""
    if run("git", "-C", project, "status", "--porcelain", "--untracked-files=all"):
        return f"{project} has uncommitted or untracked files."
    local = run("git", "-C", project, "rev-parse", "HEAD")
    if local != head:
        return f"HEAD is {local}, not the PR head {head}."
    return None


def caller_record() -> tuple[Record, str]:
    """The allocation record of the calling pane and the entry it runs."""
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane:
        raise RuntimeError("HERDR_PANE_ID is not set; run this from your own pane")
    me = herdr("agent", "get", pane)["agent"].get("name") or ""
    for record in records().values():
        for entry, allocation in record["agents"].items():
            if me and allocation["name"] == me:
                return record, entry
    raise RuntimeError(f"This pane is {me or 'unnamed'}, not a launched client")


def poster(allocation: Allocation) -> tuple[str, str, str]:
    """The (role, name, session) attribution of comments the client posts."""
    return event_role(allocation), allocation["name"], allocation["session"]


def required_reviewers(record: Record) -> list[str]:
    """The brief's current `Required reviews:` entries, merge-confirming tester first."""
    testers, designers = current_roster(record)
    return [record["tester"], *testers, *designers]


def findings_text(known: list[tuple[str, str]]) -> str:
    if not known:
        return ""
    return "Open findings: " + "; ".join(f"{check} {url}" for check, url in known) + ". "


def bootstrap_command(head: str) -> str:
    return f"python3 {harness() / 'bootstrap.py'} --commit {head}"


def tester_message(
    record: Record, pr: str, url: str, head: str, missing: list[str], known: list[tuple[str, str]]
) -> str:
    implementer, tester = record["implementer"], record["tester"]
    message = f"Your turn: review {url} at {head}. This handoff notified every launched "
    message += "required reviewer of this head"
    if missing:
        message += f" and asked the dispatcher to launch {', '.join(missing)}"
    message += ". " + findings_text(known)
    message += (
        f"Move your own clone to the head first: {bootstrap_command(head)}; it refuses a "
        "dirty clone. Follow agent/teams/roles/tester.md and "
        "agent/skills/review-software-correctness/SKILL.md from your clone and use the "
        "README PR review record. "
        f"Put {tester}, <session> on line 2; replace <session> with your session ID. "
        "When your review or any required reviewer's latest review of this head has findings, "
        f"run {turn_command(implementer).replace('<pr>', pr)}; do not wait for the other "
        f"reviews. Follow the README merge step when python3 {harness() / 'pr_review.py'} "
        f"observe {pr} reports ready to merge. After the merge, notify the dispatcher with "
        f"herdr agent prompt dispatcher '{url} done'."
    )
    return message


def reviewer_notice(record: Record, entry: str, url: str, head: str) -> str:
    tester = live_name(record["slot"], record["tester"])
    return (
        f"New head to review on {url}: {head}. Move your own clone to it with "
        f"{bootstrap_command(head)}; it refuses a dirty clone and never resets one. Review "
        f"the changes since your last review. Submit the README review record with {entry}, "
        f"<session> on line 2, then send its URL with herdr agent prompt {tester} "
        "'<review URL>'."
    )


def implementer_message(pr: str, url: str, known: list[tuple[str, str]]) -> str:
    tools = harness() / "pr_review.py"
    message = f"Your turn on {url}: run python3 {tools} list {pr} and "
    message += f"python3 {tools} observe {pr}. " + findings_text(known)
    message += (
        "Fix review findings, failed checks and open findings following "
        "agent/skills/implement-software/SKILL.md from your clone. Push your changes, then "
        "run turn to the tester again; it notifies every required reviewer. "
        "If blocked, follow the README blocker procedure."
    )
    return message


def observe_pr(pr: str, head: str, allocation: Allocation) -> tuple[list[tuple[str, str]], str]:
    """Record the PR's failures at this head as the caller. Return each open finding's check
    and URL, and the conflict the current read shows: "current", "unknown" or ""."""
    import pr_review  # pr_review imports this module, so load it only when needed.

    state, known = pr_review.observe(int(pr), poster(allocation), head)
    conflict = {"CONFLICTING": "current", pr_review.UNAVAILABLE: "unknown"}
    return [(f.check, url) for f, url in known.items()], conflict.get(state.mergeable, "")


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


def request_launch(
    record: Record, me: str, pr: str, url: str, head: str, missing: list[str]
) -> list[str]:
    """Record a pending notice on the PR and ask the dispatcher to launch the reviewers."""
    failed: list[str] = []
    try:
        post_event(
            pr,
            record["agents"][me],
            f"pending review of {head} by {', '.join(missing)}: not launched; "
            "launch requested from the dispatcher",
        )
    except RuntimeError as error:
        failed.append(str(error))
    commands = "; ".join(f"agent/teams/team.py review {pr} {entry}" for entry in missing)
    return failed + deliver([("dispatcher", f"{url} review: run {commands}")])


def conflict_refusal(head: str, links: list[str], conflict: str) -> str:
    if conflict == "unknown":
        return (
            f"Known merge conflict {', '.join(links)}, and GitHub has not reported "
            f"mergeability for {head} yet: rerun turn shortly. Nobody was notified."
        )
    return (
        f"Known merge conflict {', '.join(links)}: merge origin/main and push, or report "
        "blocked. Nobody was notified."
    )


def hand_to_reviewers(
    record: Record, me: str, pr: str, url: str, head: str, known: list[tuple[str, str]]
) -> None:
    """Notify every required reviewer of one head; request launch of the missing ones."""
    reviewers = required_reviewers(record)
    missing = [entry for entry in reviewers if entry not in record["agents"]]
    tester = live_name(record["slot"], record["tester"])
    sends = [(tester, tester_message(record, pr, url, head, missing, known))]
    sends += [
        (live_name(record["slot"], entry), reviewer_notice(record, entry, url, head))
        for entry in reviewers[1:]
        if entry in record["agents"]
    ]
    failed = deliver(sends)
    if missing:
        failed += request_launch(record, me, pr, url, head, missing)
    if failed:
        raise RuntimeError(
            "Handoff incomplete; failed sends: " + "; ".join(failed) + ". Report blocked with "
            "these errors, or rerun turn after fixing them."
        )


def turn(pr: str, recipient: str) -> None:
    """Hand a pushed head to every required reviewer, or hand findings to the implementer.

    Both directions first record the PR's failures; a failure that cannot be recorded
    blocks the handoff.
    """
    record, me = caller_record()
    pair = {record["implementer"], record["tester"]}
    if me not in pair or recipient not in pair or recipient == me:
        raise RuntimeError(
            f"turn hands work between {record['implementer'] or 'no implementer'} and "
            f"{record['tester'] or 'no tester'}; this pane is {me}"
        )
    url, head, briefs = pull_request(pr)
    if record["brief"] not in briefs:
        raise RuntimeError(
            f"PR {pr} does not close brief #{record['brief']} (closes {briefs or 'nothing'}); "
            "fix the PR's closing reference first"
        )
    if recipient == record["tester"]:
        # The handed-off commit is the implementer's own clean, pushed HEAD.
        problem = checkout_problem(project_of(record["agents"][me]), head)
        if problem:
            raise RuntimeError(f"{problem} Commit and push, then hand over.")
    known, conflict = observe_pr(pr, head, record["agents"][me])
    conflicts = [link for check, link in known if check == "mergeability"]
    if recipient == record["tester"] and conflicts:
        raise RuntimeError(conflict_refusal(head, conflicts, conflict))
    if recipient == record["implementer"]:
        partner = live_name(record["slot"], recipient)
        herdr("agent", "prompt", partner, implementer_message(pr, url, known))
        print(f"Notified {partner}")
    else:
        hand_to_reviewers(record, me, pr, url, head, known)
    print("End your turn now.")


# --- Retirement and stop ---------------------------------------------------

def retirement_reports(record: Record) -> Reports:
    """Each allocation's latest retirement report on the issue from its current launch:
    posted under the client's recorded name and session, naming the recorded launch. A
    report from an earlier launch is no evidence. Reports are advisory evidence."""
    current = {a["id"]: (a["name"], a["session"], a["launch"]) for a in record["agents"].values()}
    reports: Reports = {}
    for comment in issue_comments(record["brief"]):
        lines = str(comment.get("body") or "").splitlines()
        header = HEADER.match(lines[0]) if lines else None
        if not header or header["type"] != "EVENT":
            continue
        for line in lines[1:]:
            if line.startswith(RETIREMENT):
                try:
                    fields = object_fields(json.loads(line[len(RETIREMENT) :]), "report")
                except ValueError:
                    continue  # a malformed report is no evidence
                ident = str(fields.get("id"))
                found = (header["name"], header["session"], fields.get("launch"))
                if fields.get("launch") and current.get(ident) == found:
                    reports[ident] = (fields, str(comment["html_url"]))
    return reports


def never_launched(allocation: Allocation) -> bool:
    """No client was ever entered in the allocation: launch ids are saved only after one
    is, so there is no session to report and no work in its clone."""
    return not allocation["launch"] and allocation["submission"] == NEVER_SUBMITTED


def request_reports(record: Record, missing: list[str], running: set[str]) -> None:
    """Ask each running client without a report to post one, name the operator command for
    each stopped one, then refuse: every resource stays reserved until stop runs again."""
    command = f"python3 {harness() / 'retirement.py'}"
    sends = [
        (record["agents"][e]["name"], f"Retire: run {command}, then end your turn.")
        for e in missing
        if e in running
    ]
    failed = deliver(sends)
    stopped = [
        f"{a['name']}: cd {a['root']} && TIPS_TEAM_STATE={conf.state_dir()} "
        f"TIPS_TEAM_ALLOCATION_ID={a['id']} TIPS_TEAM_LAUNCH={a['launch']} {command}"
        for e, a in record["agents"].items()
        if e in missing and e not in running
    ]
    raise RuntimeError(
        f"No retirement report yet from {', '.join(record['agents'][e]['name'] for e in missing)}."
        f" Asked: {', '.join(n for n, _ in sends) or 'none'}; failed sends: "
        f"{'; '.join(failed) or 'none'}. Not running, so the operator reports for them: "
        f"{'; '.join(stopped) or 'none'}. Every resource stays reserved; run stop again after "
        "the reports are posted."
    )


def retirement_paths(allocation: Allocation) -> tuple[Path, Path, Path, Path]:
    """The allocation's directories, refused unless the record names its canonical
    allocation and no path leaves the harness root or passes through a symlink."""
    paths = allocation_paths(allocation["id"])
    if Path(allocation["root"]) != paths[0]:
        raise RuntimeError(
            f"{allocation['name']}: recorded allocation {allocation['root']} is not "
            f"{paths[0]}; preserved"
        )
    trusted = conf.harness_root()
    for directory in paths:
        if directory.exists() or directory.is_symlink():
            contained(directory, trusted)
    return paths


def verify_present(present: dict[str, Allocation]) -> None:
    """Validate every recorded pane before stopping any client."""
    for allocation in present.values():
        root, live = pane_occupant(allocation["pane"])
        if live:
            agent = herdr("agent", "get", allocation["pane"])["agent"]
            if agent.get("name") != allocation["name"] or root != Path(allocation["root"]):
                raise RuntimeError(f"{allocation['pane']}: conflicting owner; preserved")


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


def port_in_use(port: int) -> bool:
    """Whether anything listens on the port; anything but a refused connection counts."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        return probe.connect_ex(("127.0.0.1", port)) != errno.ECONNREFUSED


def merged_brief(brief: str) -> bool:
    """Whether GitHub reports the brief closed by a merged PR. stop holds the store lock, so
    every read shares one timeouts.shell_seconds budget; a late answer keeps the record."""
    seconds = conf.settings()["timeouts"]["shell_seconds"]
    deadline = time.monotonic() + seconds

    def read(*args: str) -> object:
        try:
            return json.loads(run(*args, timeout=max(deadline - time.monotonic(), 0.01)))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                f"GitHub did not answer within {seconds} s whether #{brief} is closed by a "
                "merged PR; the record and reservation are kept"
            ) from error

    fields = "state,closedByPullRequestsReferences"
    view = object_fields(read("gh", "issue", "view", brief, *repo_args(), "--json", fields), brief)
    if view.get("state") != "CLOSED":
        return False
    for pr in object_list(view.get("closedByPullRequestsReferences") or [], f"#{brief} PRs"):
        state = read("gh", "pr", "view", str(pr.get("number")), *repo_args(), "--json", "state")
        if object_fields(state, "PR state").get("state") == "MERGED":
            return True
    return False


def preservation_gap(record: Record, reports: Reports) -> str:
    """Why the reports do not show the team's work preserved, or "": every client reported
    a clean clone with nothing unpushed and, for a brief, a HEAD merged into origin/main. A
    design team commits nothing, so it needs no merge."""
    for allocation in record["agents"].values():
        if never_launched(allocation):
            continue
        fields, url = reports[allocation["id"]]
        if fields.get("clean") is not True or fields.get("unpushed") != 0:
            return f"{allocation['name']} reported uncommitted or unpushed work: {url}"
        if record["kind"] != "design" and fields.get("merged") is not True:
            return f"{allocation['name']} reported a HEAD not merged into origin/main: {url}"
    return ""


def recorded_databases(name: str, suffixes: list[str]) -> bool:
    """Whether the database is one of the recorded stems or a numbered partition of one."""
    stems = [base + suffix for base in DATABASE_BASES for suffix in suffixes]
    return any(re.fullmatch(re.escape(stem) + r"[0-9]*", name) for stem in stems)


def drop_databases(suffixes: list[str]) -> list[str]:
    """Drop exactly the recorded databases and their numbered partitions with the trusted
    psql command: no FORCE, no project compose or configuration. The first refusal stops
    the drop and keeps the reservation."""
    psql = [*conf.settings()["team"]["psql"], "-X", "-v", "ON_ERROR_STOP=1"]
    timeout = conf.settings()["timeouts"]["launch_seconds"]
    listing = execute(
        [*psql, "-Atc", "SELECT datname FROM pg_database"], cwd=conf.state_dir(), timeout=timeout
    )
    if listing.returncode:
        raise RuntimeError(f"psql could not list databases: {listing.stderr.strip()}; preserved")
    dropped: list[str] = []
    for db in listing.stdout.splitlines():
        if recorded_databases(db, suffixes):
            # Without FORCE, a remaining connection makes PostgreSQL refuse the drop.
            statement = 'DROP DATABASE "' + db.replace('"', '""') + '"'
            result = execute([*psql, "-c", statement], cwd=conf.state_dir(), timeout=timeout)
            if result.returncode:
                raise RuntimeError(
                    f"PostgreSQL refused to drop {db}: {result.stderr.strip()}. Dropped: "
                    f"{', '.join(dropped) or 'none'}; the rest and the reservation are kept."
                )
            dropped.append(db)
    return dropped


def remove_if_empty(directory: Path) -> None:
    """Remove an empty directory; one that holds anything stays."""
    try:
        directory.rmdir()
    except FileNotFoundError:
        pass
    except OSError as error:
        if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
            raise


def retain_files(record: Record, dropped: list[str], kept: str, reports: Reports) -> None:
    """Remove only empty residue; record in each allocation's launcher configuration what it
    leaves behind and why. Project files are never deleted."""
    for allocation in record["agents"].values():
        root, project, logs, config = retirement_paths(allocation)
        for directory in (project, logs, root):
            remove_if_empty(directory)
        retained = [str(path) for path in (project, logs) if path.exists()]
        own = [db for db in dropped if recorded_databases(db, [allocation["db_suffix"]])]
        note = {
            "id": allocation["id"],
            "issue": record["brief"],
            "retained": retained,
            "reason": "project and log files are never deleted automatically",
            "report": reports.get(allocation["id"], ({}, ""))[1],
            "db_suffix": allocation["db_suffix"],
            "databases_dropped": own,
            "databases_kept_because": kept,
        }
        staged = config / "retired.json.tmp"
        staged.write_text(json.dumps(note, indent=2, sort_keys=True) + "\n")
        staged.replace(config / "retired.json")
        for path in retained:
            print(f"Retained {path}: {note['reason']}; see {config / 'retired.json'}")


def list_retained() -> None:
    """List each retired allocation that still has files, with why it was kept. Deletes
    nothing: a writer outside the pane can outlive stop, so only the operator, having
    established that the work is preserved and every writer has stopped, deletes an
    allocation by its ID."""
    found = False
    for path in sorted(conf.state_dir().glob("*/retired.json")):
        note = object_fields(json.loads(path.read_text()), str(path))
        root = allocation_paths(str(note.get("id")))[0]
        if not root.exists():
            continue
        found = True
        kept = note.get("databases_kept_because") or "dropped"
        print(
            f"{note.get('id')} (#{note.get('issue')}): {root}; files: {note.get('reason')}; "
            f"databases {note.get('db_suffix')}: {kept}; report: {note.get('report') or 'none'}"
        )
    if not found:
        print("No retained allocations")


def stop_brief(brief: str) -> None:
    """Stop a team's recorded clients and Dexter daemons and release its slot.

    A brief must be closed by a merged PR before any client is asked. Every client then
    posts a retirement report from its current launch. Work that the reports do not show
    preserved keeps everything: nothing is stopped and the record stays. Databases are
    dropped only for merged work; project and log files are always retained. A conflict, a
    failed stop or a busy port keeps the reservation, so stop can run again.
    """
    with store_lock():
        record = record_for(brief)
        if record is None:
            print(f"#{brief}: no allocation record; nothing removed")
            return
        # A brief still in progress is never interrupted: a wrong issue number asks no one.
        if record["kind"] != "design" and not merged_brief(brief):
            raise RuntimeError(
                f"#{brief} is not closed by a merged PR. Nothing was asked or stopped; the "
                "record, databases, files and reservation are kept. If the brief was closed "
                "without a merged PR, the operator retires it by hand; until then the slot "
                "stays taken: agent/teams/README.md#retire-a-brief-closed-without-a-merged-pr"
            )
        require_only_recorded_panes(record)
        paths = [retirement_paths(a) for a in record["agents"].values()]
        roots = [root for root, *_ in paths]
        names = [a["name"] for a in record["agents"].values()]
        panes = frozenset(a["pane"] for a in record["agents"].values())
        refuse_foreign_owner(roots, names, panes)
        reports = retirement_reports(record)
        present = {
            e: a for e, a in record["agents"].items() if running_client(record, a) is not None
        }
        missing = [
            e
            for e, a in record["agents"].items()
            if a["id"] not in reports and (e in present or not never_launched(a))
        ]
        if missing:
            request_reports(record, missing, set(present))
        gap = preservation_gap(record, reports)
        if gap:
            raise RuntimeError(
                f"#{brief}: {gap}. Nothing was stopped; the record, databases, files and "
                "reservation are kept. Preserve the work (commit, push and merge it), have the "
                "client report again, then rerun stop."
            )
        verify_present(present)
        for allocation in present.values():
            stop(allocation["pane"], allocation["root"])
        refuse_foreign_owner(roots, names, panes)
        # Rechecked at the close itself: a pane may have arrived during the shutdown.
        if require_only_recorded_panes(record):
            herdr("workspace", "close", record["workspace"])
        for _, project, _, config in paths:
            stop_daemon(project, config)
        busy = [str(a["port"]) for a in record["agents"].values() if port_in_use(a["port"])]
        if busy:
            raise RuntimeError(f"Ports {', '.join(busy)} are in use; the reservation is kept")
        kept = "a design team's databases are kept" if record["kind"] == "design" else ""
        suffixes = [a["db_suffix"] for a in record["agents"].values()]
        dropped = [] if kept else drop_databases(suffixes)
        retain_files(record, dropped, kept, reports)
        record_path(record["slot"]).unlink()
    summary = f"databases dropped: {', '.join(dropped) or 'none'}"
    if kept:
        summary += f"; databases {', '.join(suffixes)} kept: {kept}"
    print(f"#{brief}: slot {record['slot']} released; {summary}")


def require_only_recorded_panes(record: Record) -> bool:
    """Require every pane of the team's workspace to be recorded; closing the workspace
    closes them all. Return whether the workspace is live."""
    panes = live_panes(record["workspace"])
    recorded = {a["pane"] for a in record["agents"].values()}
    strangers = [p["pane_id"] for p in panes if p["pane_id"] not in recorded]
    if strangers:
        raise RuntimeError(
            f"Workspace of #{record['brief']} holds other panes {strangers}; preserved"
        )
    return bool(panes)


def client_state(allocation: Allocation, panes: set[str], agents: dict[str, Entity]) -> str:
    """One recorded client's live state: Herdr's pane and agent identity, not the record alone."""
    pane, session = allocation["pane"], allocation["session"] or "none"
    kind = f"{allocation['role']}, {allocation['kind']}"
    head = f"{allocation['entry']} ({kind}) {allocation['name']}"
    if pane not in panes:
        return f"{head}: pane {pane or 'none'} missing; recorded session {session}"
    agent = agents.get(pane)
    if agent is None:
        return f"{head}: pane {pane} at the shell, client exited; recorded session {session}"
    if agent.get("name") != allocation["name"] or agent.get("agent") != allocation["kind"]:
        holder = f"{agent.get('name') or 'unnamed'} ({agent.get('agent')})"
        return f"{head}: pane {pane} holds {holder}, not the recorded client; preserved"
    live = session_id(agent) or "unknown"
    state = agent.get("agent_status") or "unknown"
    started = "running" if allocation["session"] else "startup incomplete"
    return f"{head}: {started} in {pane}, {state}; live session {live}, recorded {session}"


# --- Dispatcher record, status and CLI -------------------------------------

def dispatcher_path() -> Path:
    return conf.harness_root() / "state/dispatcher.json"


def dispatcher_note(name: str, session: str) -> str | None:
    """The text of a ready or recovery note written for this launch's session, else None."""
    path = dispatcher_path().with_name(name)
    try:
        fields = object_fields(json.loads(path.read_text()), str(path))
    except (OSError, ValueError, RuntimeError):
        return None
    return str(fields.get("text", "")) if fields.get("session") == session else None


def dispatcher_launch() -> DispatcherLaunch | None:
    path = dispatcher_path()
    if not path.exists():
        return None
    fields = object_fields(json.loads(path.read_text()), str(path))
    require_type(fields.get("pid"), int, f"{path} pid")
    for key in ("started", "pane", "session"):
        require_type(fields.get(key), str, f"{path} {key}")
    return cast(DispatcherLaunch, fields)


def start_time(pid: int) -> str | None:
    """The process's start time as ps prints it, spacing normalized; None if not running."""
    row = processes().get(pid)
    return " ".join(row[1].split()) if row else None


def dispatcher_running(launch: DispatcherLaunch) -> bool:
    """Whether the recorded process still runs: the same process id and start time."""
    return start_time(launch["pid"]) == " ".join(launch["started"].split())


def record_dispatcher(pane: str, session: str) -> DispatcherLaunch:
    """Record this process, which is about to exec the client, as the dispatcher."""
    pid = os.getpid()
    started = start_time(pid)
    if started is None:
        raise RuntimeError(f"ps does not list this process ({pid})")
    launch = DispatcherLaunch(pid=pid, started=started, pane=pane, session=session)
    path = dispatcher_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = path.with_suffix(".next")
    staged.write_text(json.dumps(launch) + "\n")
    staged.replace(path)
    return launch


def dispatcher_status(named: Entity | None) -> str:
    launch = dispatcher_launch()
    if launch and dispatcher_running(launch):
        held = f"pid {launch['pid']} in {launch['pane']}, session {launch['session']}"
        state = named.get("agent_status") if named else None
        if named and named.get("pane_id") != launch["pane"]:
            return f"dispatcher: {held}; the agent named dispatcher is in {named['pane_id']}"
        # The starter's note when it could not start this launch; the next launch clears it.
        recovery = dispatcher_note(DISPATCHER_RECOVERY, launch["session"])
        hint = f"; starter note: {recovery}" if recovery else ""
        return f"dispatcher: running, {held}, {state or 'no Herdr name'}{hint}"
    if named:
        return f"dispatcher: {named['pane_id']} is named dispatcher but is not the recorded launch"
    return "dispatcher: not running"


def status() -> None:
    """Print every allocation record with each client's live Herdr state and the dispatcher's."""
    agents = {a["pane_id"]: a for a in herdr("agent", "list")["agents"]}
    named = {a.get("name"): a for a in agents.values()}
    print(dispatcher_status(named.get("dispatcher")))
    found = records()
    if not found:
        print("No allocation records.")
    for slot, record in sorted(found.items()):
        panes = {p["pane_id"] for p in live_panes(record["workspace"])}
        workspace = record["workspace"] or "none"
        if record["workspace"] and not panes:
            workspace += " (closed)"
        print(f"slot {slot}: brief #{record['brief']}, workspace {workspace}")
        for _, allocation in sorted(record["agents"].items()):
            print("  " + client_state(allocation, panes, agents))


def prompt_agent(brief: str, entry: str, text: str) -> None:
    """Send text to a recorded client of the brief once its pane holds that same client.

    The target is a recorded role, never a pane: an unrecorded or replaced client is refused.
    Any failure of the prompt call, including Herdr's own timeout, may come after the text
    reached the client, so the error says delivery is unknown and not to resend blindly.
    """
    record = record_for(brief)
    if record is None:
        raise RuntimeError(f"Brief #{brief} has no allocation record")
    allocation = record["agents"].get(entry)
    if allocation is None:
        raise RuntimeError(f"Brief #{brief} has no launched {entry}")
    if allocation["pane"] not in {p["pane_id"] for p in live_panes(record["workspace"])}:
        raise RuntimeError(f"{allocation['name']}: recorded pane {allocation['pane']} is gone")
    if running_client(record, allocation) is None:
        raise RuntimeError(f"{allocation['name']} is not running in {allocation['pane']}")
    try:
        herdr("agent", "prompt", allocation["name"], text)
    except (subprocess.TimeoutExpired, RuntimeError, ValueError) as error:
        raise RuntimeError(
            f"Prompt to {allocation['name']} failed ({error}); it may have been delivered. "
            "Read the agent's records before sending it again."
        ) from error
    print(f"Prompted {allocation['name']}")


def stop_agent(pane: str, root: str | Path) -> None:
    """Stop the client gracefully; raise an error if its exit is uncertain.

    The caller must keep the checkout.
    """
    conf.configure()
    stop(pane, root)


def cli() -> None:
    conf.configure()
    args = sys.argv[1:]
    usage = (
        "Usage: agent/teams/team.py start <brief> | design <spec> <entry> | "
        "turn <pr> <entry> | review <pr> <entry> | reset <issue> <entry> | stop <issue> | "
        "clean | status"
    )
    if args == ["status"]:
        status()
        return
    if args == ["clean"]:
        list_retained()
        return
    if len(args) < 2 or not args[1].isdecimal():
        raise RuntimeError(usage)
    named = len(args) == 3 and re.fullmatch(ENTRY, args[2]) is not None
    if args[0] == "start" and len(args) == 2:
        start(args[1])
    elif args[0] == "stop" and len(args) == 2:
        stop_brief(args[1])
    elif args[0] == "turn" and named:
        turn(args[1], args[2])
    elif args[0] == "design" and named:
        design(args[1], args[2])
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
