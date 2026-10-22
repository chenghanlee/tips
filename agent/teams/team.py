#!/usr/bin/env python3
"""Manage teams in Herdr: start a brief's pair, launch reviewers and designers, hand off, stop.

Configured agents are `[agents.<entry>]` in config.toml. Every client gets an allocation with
a generation ID that never repeats: an empty project directory it clones into itself with
bootstrap.py, a logs directory, and launcher configuration, all under the harness root
`agent_teams/<repository name>/` beside the main checkout. The slot's record in the root's
`state/` holds the record version, the brief or spec, its roster, and every launched client's
Herdr name, kind, project, database suffix, port, pane, session and task-submission state.
Restart, handoff and retirement use that record. The issue's `phase:` and `turn:` labels
record the workflow step and its coordinating owner (README.md#turns). One lock on
`state/.lock` serializes start, design, review, reset, stop and cleanup. This controller
never runs a build or a worker-provided executable in a project. Its only Git commands
there are cleanup's fetch and read-only checks in a stopped allocation's clone, with hooks
and fsmonitor off.
"""

import contextlib
import errno
import fcntl
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid
from collections.abc import Generator
from pathlib import Path
from typing import NotRequired, TypedDict, cast

import config as conf
from briefs import (
    conflict_refusal,
    design_brief,
    implementer_message,
    launch_text,
    pair_brief,
    reviewer_brief,
    reviewer_notice,
    tester_message,
    ux_team_brief,
)
from commands import execute, object_fields, require_type, run, write_file
from config import (
    DISPATCHER_RECOVERY,
    ENTRY,
    NAME_BYTES,
    NATIVE_LSP_PLUGINS,
    NEVER_SUBMITTED,
    RECORD_VERSION,
    SUBMITTED,
    TABS,
    UNKNOWN,
    UX_ROLES,
    Allocation,
    DispatcherLaunch,
    Entity,
    Record,
    agent_spec,
    allocation_id,
    allocation_paths,
    allocation_port,
    config_location,
    contained,
    database_stem,
    harness,
    live_name,
    names_fit,
    namespace_of,
    overlapping,
    project_of,
    slot_record_paths,
    unretired_allocations,
    within,
)
from dexter import stop_daemon, tools
from github import (
    WORKFLOW,
    Phase,
    PullRequest,
    approved_candidate,
    event_posted,
    merged_brief,
    post_event,
    pull_request,
    replace_labels,
    roster,
    spec_lead,
    ux_team,
)
from herdr import deliver, herdr, live_panes, pane_occupant, processes, session_id, stop

# --- Records and allocations -----------------------------------------------


def record_path(slot: int) -> Path:
    return conf.state_dir() / f"{slot}.json"


def next_generation() -> int:
    """A generation this store never handed out before; call it under the lock."""
    path = conf.state_dir() / "generation"
    last = int(path.read_text()) if path.is_file() else 0
    write_file(path, f"{last + 1}\n")
    return last + 1


def require_current_record(path: Path, fields: dict[str, object]) -> None:
    """Refuse a record another team.py version wrote."""
    if fields.get("version") != RECORD_VERSION:
        raise RuntimeError(
            f"{path}: record version {fields.get('version')!r} is not {RECORD_VERSION}; preserved"
        )


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
    """Replace the slot's record durably: once this returns, a launcher crash or timeout
    keeps the new record."""
    path = record_path(record["slot"])
    path.parent.mkdir(parents=True, exist_ok=True)
    write_file(path, json.dumps(record, indent=2, sort_keys=True) + "\n")


@contextlib.contextmanager
def store_lock() -> Generator[None]:
    """Hold the record store's lock: one start, design, review, reset or stop at a time.

    The lock is on a file that is never replaced, so it is not lost when a record is
    rewritten. The kernel releases it when this process exits, even after a crash. Python
    opens the file non-inheritable and `subprocess` closes other descriptors by default, so
    a child does not receive it.
    """
    path = conf.state_dir() / conf.STORE_LOCK
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
    found: dict[int, Record] = {}
    for path in slot_record_paths(conf.state_dir()):
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


# --- Tools and the client environment --------------------------------------


def test_port(entry: str, slot: int) -> int:
    offset = conf.settings()["agents"][entry]["port_offset"]
    return allocation_port(conf.settings()["team"], slot, offset)


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
        "TIPS_TEAM_STATE": str(conf.state_dir()),
    }
    if allocation["kind"] == "codex":
        # Codex's sandbox cannot write the shared Hex cache in the home directory.
        env["HEX_HOME"] = str(project / "tmp/hex")
    return env


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
    if not names_fit(suffix):
        raise RuntimeError(f"{entry}: database names for {suffix} exceed {NAME_BYTES} bytes")
    ident = allocation_id(generation, entry)
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
    for config in unretired_allocations(conf.state_dir()):
        path = config / "bootstrap.json"
        settings = object_fields(json.loads(path.read_text()), str(path))
        issue_entry = (settings.get("issue"), settings.get("entry"))
        if issue_entry == (record["brief"], entry) and config.name not in held:
            found.append(f"allocation {config.name}")
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
        "role": allocation["role"],
        "project": str(project),
        "logs": str(logs),
        "clone_url": conf.settings()["team"]["clone_url"],
        "repository": conf.settings()["github"]["repository"],
        "github_seconds": conf.github_seconds(),
        "startup_seconds": conf.settings()["timeouts"]["dexter_startup_seconds"],
        "branch": branch,
        "commit": commit,
        "dexter": str(binary),
        "sources": str(sources),
        "skills": str(skills),
        # What the launch lets the worker write; bootstrap refuses trusted paths inside it.
        "writable": [allocation["root"]],
    }
    write_file(config / "bootstrap.json", json.dumps(settings, indent=2, sort_keys=True) + "\n")


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
            if agent.get("name") not in names and within(cwd, root):
                owner = agent.get("name") or agent["pane_id"]
                raise RuntimeError(f"Conflicting live agent in {root}: {owner}; preserved")


# --- Launch: panes, briefs, clients and recovery ---------------------------


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
        record["workspace"] = created["workspace"]["workspace_id"]
        record["tabs"] = {label: created["tab"]["tab_id"]}
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
    # Recorded before any rename: a failure below must still find the workspace and pane.
    allocation["workspace"] = record["workspace"]
    allocation["tab"] = record["tabs"][label]
    allocation["pane"] = pane["pane_id"]
    save_record(record)
    if not panes:
        herdr("tab", "rename", record["tabs"][label], label)
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


# Harness scripts a client runs under its own authority (common.md Comments).
CLIENT_SCRIPTS = ("board.py", "pr_review.py")
# GitHub writes the roles assign: brief and PR body maintenance, comments and reviews.
# The merge and the handoff stay with the client's permission mode (SETUP.md).
GITHUB_WRITES = ("issue edit", "issue comment", "pr create", "pr edit", "pr comment", "pr review")


def allowed_commands() -> list[str]:
    """Permission rules for the role's own duties, which auto mode's classifier has
    denied as external writes (`gh issue edit` on the client's brief)."""
    return [
        *(f"Bash(gh {command}:*)" for command in GITHUB_WRITES),
        *(f"Bash(python3 {harness() / script}:*)" for script in CLIENT_SCRIPTS),
    ]


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
    if spec["kind"] == "agy":
        # Gemini's agy CLI, used by graphic designers. Its mode and effort flags come from
        # `agy --help`; the real launch in the trial verifies their effect.
        args = ["--mode", "auto", "--effort", spec["effort"]]
        if spec["model"]:
            args += ["--model", spec["model"]]
        return args
    args = [
        "--permission-mode",
        policies["claude_permission_mode"],
        "--effort",
        spec["effort"],
        "--settings",
        json.dumps(
            {
                "enabledPlugins": {"mix-credo@elixir-agent-tools": True, **NATIVE_LSP_PLUGINS},
                # No human reads a pair pane; a suggestion is a wasted request per turn.
                "promptSuggestionEnabled": False,
                "permissions": {"allow": allowed_commands()},
            }
        ),
        "--append-system-prompt",
        prompt,
        "--session-id",
        session,
    ]
    if spec["model"]:
        args += ["--model", spec["model"]]
    return args


def running_client(record: Record, allocation: Allocation) -> Entity | None:
    """The recorded client if it is live in its pane; None if the pane is gone or at the shell.

    A live client with another name, kind, root or session makes the pane's owner
    uncertain: refused, and so is one that reports no session, since nothing then shows
    which client is live. Only a record with no session yet accepts the live one's. A
    refusal states the fact; checked_client adds the caller's next step.
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
            f"{pane}: {name} reports no session; cannot confirm the recorded client; preserved"
        )
    if recorded and live_session != recorded:
        raise RuntimeError(f"{pane}: {name} runs session {live_session}, not {recorded}; preserved")
    return agent


def checked_client(record: Record, allocation: Allocation, step: str) -> Entity | None:
    """running_client, with the caller's next step added to a refusal."""
    try:
        return running_client(record, allocation)
    except RuntimeError as error:
        raise RuntimeError(f"{error}. {step}") from error


def harness_command(script: str, *args: str) -> str:
    """The shell command that runs a harness script, quoted for the operator or a client."""
    return shlex.join(["python3", str(harness() / script), *args])


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
    agent = checked_client(
        record, allocation, "Nothing was resent; only the operator decides what happens to it."
    )
    name, state = allocation["name"], allocation["submission"]
    if agent and state == NEVER_SUBMITTED:
        raise RuntimeError(
            f"{name} is live in {allocation['pane']}, but this record never started it; preserved"
        )
    if agent is None and state != NEVER_SUBMITTED:
        reset = harness_command("team.py", "reset", record["brief"], allocation["entry"])
        raise RuntimeError(
            f"{name} is not running and its task submission is {state}. It may have done the "
            "task before it exited, so nothing was launched or resent; only the operator "
            "decides whether to replay it: after checking its work on the brief and PR, the "
            f"operator runs {reset}, then reruns this command."
        )
    return agent


def adopt(record: Record, allocation: Allocation, agent: Entity) -> None:
    """Keep a live recorded client; never resend its task. If the launch stopped before the
    record held a session, record the one the client reports; running_client refused any
    other mismatch. Post the launch EVENT if the launch stopped before it was posted."""
    name, session = allocation["name"], session_id(agent)
    if session and not allocation["session"]:
        allocation["session"] = session
        save_record(record)
    text = launch_text(allocation)
    if not event_posted(record["brief"], allocation, text):
        post_event(record["brief"], allocation, text)
    if allocation["submission"] == SUBMITTED:
        return
    print(
        f"{name}: task submission is {allocation['submission']}; nothing was resent. Only the "
        f"operator decides whether to replay it: if {allocation['pane']} shows that the client "
        "never got its task, the operator exits the client, runs "
        f"{harness_command('team.py', 'reset', record['brief'], allocation['entry'])} and "
        "reruns this command."
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
    timeouts = conf.settings()["timeouts"]
    herdr(
        "agent",
        "start",
        name,
        "--kind",
        kind,
        "--pane",
        pane,
        "--timeout",
        str(timeouts["launch_seconds"] * 1000),
        "--",
        *args,
        # Herdr's own launch timeout must answer before this one kills the command.
        timeout=timeouts["launch_seconds"] + timeouts["shell_seconds"],
    )
    started = herdr("agent", "get", pane)["agent"]
    reported = session_id(started)
    if not session:
        allocation["session"] = reported
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
    print(f"Launched {name}: {kind} in {root}, session {allocation['session'] or 'unknown'}")
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


# --- Workflow labels --------------------------------------------------------


def assign(issue: str, phase: Phase, owner: str) -> None:
    """Record the issue's workflow step and coordinating owner (README.md#turns)."""
    replace_labels(issue, WORKFLOW, [f"phase:{phase}", f"turn:{owner}"])
    print(f"#{issue} labelled phase:{phase}, turn:{owner}")


def labels_stay(phase: Phase, owner: str) -> str:
    """What a failed send after `assign` reports: the assignment is not rolled back."""
    return f"The labels phase:{phase}, turn:{owner} stay."


def start(brief: str) -> None:
    """Launch the brief's implementer and merge-confirming tester, each in its own empty
    allocation; each clones and prepares its project itself."""
    implementer, testers, _ = roster(brief)
    pair = [implementer, testers[0]]
    if ux_team(brief) is not None and not approved_candidate(brief):
        raise RuntimeError(
            f"Brief #{brief} names a UX design team; start its pair only after the user's "
            "comment beginning 'APPROVED candidate <SHA>' (README.md#ux-design-team)"
        )
    tools()  # missing tools refuse before a slot is reserved
    with store_lock():
        record = team_record(brief, "brief", *pair)
        if record["implementer"]:
            current_roster(record)
        if not record["agents"]:
            # A new pair, before any task prompt; a relaunch keeps the current labels.
            assign(brief, "implement", implementer)
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


def design(issue: str, entry: str) -> None:
    """Join a started brief or a spec with a designer in its own allocation, or launch a
    UX design team member on a brief before its pair (README.md#ux-design-team)."""
    agent = conf.settings()["agents"].get(entry)
    if agent is None or agent["role"] not in ("designer", *UX_ROLES):
        raise RuntimeError(f"{entry} is not a configured designer entry")
    role = agent["role"]
    tools()
    with store_lock():
        record = record_for(issue)
        team = None
        if role in UX_ROLES:
            if record is not None and record["kind"] == "brief":
                raise RuntimeError(
                    f"#{issue} already holds a pair in slot {record['slot']}; the UX design "
                    "team runs before the pair, so its members cannot join it"
                )
            team = ux_team(issue)
            if team is None:
                raise RuntimeError(f"Brief #{issue} has no UX: line; nothing to launch {entry} for")
            if entry != team[0] and entry not in team[1]:
                raise RuntimeError(
                    f"{entry} is not on brief #{issue}'s UX: or Graphic designers: line"
                )
            if record is None or not record["agents"]:
                record = record or team_record(issue, "design", "", "")
                assign(issue, "design", team[0])
            else:
                refuse_changed_ux_team(record, team)
        elif record is None or (record["kind"] == "design" and not record["agents"]):
            # A new standalone design team; read its lead before reserving a slot.
            lead = spec_lead(issue)
            record = record or team_record(issue, "design", "", "")
            assign(issue, "design", lead)
        elif record["kind"] == "brief":
            current_roster(record)
        if entry not in record["agents"]:
            duty = role if role in UX_ROLES else "designer"
            branch = f"task/{issue}" if role == "ux-designer" else ""
            configure_bootstrap(record, add_allocation(record, entry, duty), branch, "")
            save_record(record)
        allocation = record["agents"][entry]
        refuse_foreign_owner([Path(allocation["root"])], [allocation["name"]])
        open_pane(record, allocation)
        prompt = ux_team_brief(record, entry, *team) if team else design_brief(record, entry)
        launch(record, allocation, prompt)
    print(f"Issue {issue}: {entry} in slot {record['slot']}, {allocation['root']}")


def refuse_changed_ux_team(record: Record, team: tuple[str, list[str]]) -> None:
    """A UX design team's members are fixed once launched: the UX designer owns the
    branch, so a brief that renames its UX: or Graphic designers: entries is refused
    until the dispatcher retires the team with `stop`."""
    ux, graphics = team
    for allocation in record["agents"].values():
        entry, role = allocation["entry"], allocation["role"]
        if (role == "ux-designer" and entry != ux) or (
            role == "graphic-designer" and entry not in graphics
        ):
            raise RuntimeError(
                f"Brief #{record['brief']} changed its UX: or Graphic designers: line since "
                f"launch; {entry} still holds slot {record['slot']}. Stop the brief to "
                "retire the design team, or restore the line."
            )


def brief_record(pr: PullRequest) -> Record:
    found = [r for brief in pr.briefs if (r := record_for(brief))]
    if len(found) != 1:
        raise RuntimeError(
            f"PR {pr.number} must close exactly one started brief; closes {pr.briefs}"
        )
    return found[0]


def review(number: str, entry: str) -> None:
    """Launch a required reviewer in its own allocation, configured for the PR head."""
    pr = pull_request(number)
    with store_lock():
        record = brief_record(pr)
        testers, designers = current_roster(record)
        if entry not in testers + designers:
            raise RuntimeError(
                f"{entry} is not an additional reviewer of brief #{record['brief']} "
                f"(additional reviewers: {', '.join(testers + designers) or 'none'})"
            )
        duty = "reviewing designer" if entry in designers else "additional tester"
        allocation = record["agents"].get(entry) or add_allocation(record, entry, duty)
        allocation["pr"] = number
        save_record(record)
        refuse_foreign_owner([Path(allocation["root"])], [allocation["name"]])
        agent = reconcile(record, allocation)
        if agent:
            # A running reviewer keeps the head it was given; new heads reach it by notice.
            print(f"Already running: {allocation['name']} at {allocation.get('head')}")
            adopt(record, allocation, agent)
            return
        allocation["pr"], allocation["head"] = number, pr.head
        configure_bootstrap(record, allocation, "", pr.head)
        save_record(record)
        open_pane(record, allocation)
        launch(record, allocation, reviewer_brief(record, entry, duty, pr))
    print(f"PR {number}: {entry} reviews {pr.head} from {project_of(allocation)}")


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
        if checked_client(record, allocation, "Nothing was reset."):
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


def required_reviewers(record: Record) -> list[str]:
    """The brief's current `Required reviews:` entries, merge-confirming tester first."""
    testers, designers = current_roster(record)
    return [record["tester"], *testers, *designers]


def observe_pr(pr: PullRequest) -> tuple[str, list[str]]:
    """Read the PR at the handed-off head. Return GitHub's mergeability (MERGEABLE,
    CONFLICTING or UNAVAILABLE) and the live failures the implementer must fix."""
    import pr_review  # pr_review imports this module, so load it only when needed.

    state = pr_review.read_state(int(pr.number))
    if state.head != pr.head:
        raise RuntimeError(f"PR {pr.number} moved from {pr.head} to {state.head}; nothing sent")
    return state.mergeable, pr_review.failures(state)


def request_launch(record: Record, me: str, pr: PullRequest, missing: list[str]) -> list[str]:
    """Record a pending notice on the PR and ask the dispatcher to launch the reviewers."""
    failed: list[str] = []
    try:
        post_event(
            pr.number,
            record["agents"][me],
            f"pending review of {pr.head} by {', '.join(missing)}: not launched; "
            "launch requested from the dispatcher",
        )
    except RuntimeError as error:
        failed.append(str(error))
    commands = "; ".join(f"agent/teams/team.py review {pr.number} {entry}" for entry in missing)
    return failed + deliver([("dispatcher", f"{pr.url} review: run {commands}")])


def hand_to_reviewers(record: Record, me: str, pr: PullRequest, failures: list[str]) -> list[str]:
    """Notify every required reviewer of one head; request launch of the missing ones.
    Return the failed sends."""
    reviewers = required_reviewers(record)
    missing = [entry for entry in reviewers if entry not in record["agents"]]
    tester = live_name(record["slot"], record["tester"])
    sends = [(tester, tester_message(record, pr, missing, failures))]
    sends += [
        (live_name(record["slot"], entry), reviewer_notice(record, entry, pr))
        for entry in reviewers[1:]
        if entry in record["agents"]
    ]
    failed = deliver(sends)
    if missing:
        failed += request_launch(record, me, pr, missing)
    return failed


def turn(number: str, recipient: str) -> None:
    """Hand a pushed head to every required reviewer, or hand findings to the implementer.

    Both directions first read the PR's live state and name its current failures. A head
    that GitHub does not report mergeable is not handed to the reviewers.
    """
    record, me = caller_record()
    pair = {record["implementer"], record["tester"]}
    if me not in pair or recipient not in pair or recipient == me:
        raise RuntimeError(
            f"turn hands work between {record['implementer'] or 'no implementer'} and "
            f"{record['tester'] or 'no tester'}; this pane is {me}"
        )
    pr = pull_request(number)
    pr.require_closes(record["brief"])
    back = recipient == record["implementer"]  # findings back; otherwise a head to review
    if not back:
        # The handed-off commit is the implementer's own clean, pushed HEAD.
        problem = checkout_problem(project_of(record["agents"][me]), pr.head)
        if problem:
            raise RuntimeError(f"{problem} Commit and push, then hand over.")
    mergeable, failures = observe_pr(pr)
    if not back and mergeable != "MERGEABLE":
        raise RuntimeError(conflict_refusal(pr.head, mergeable))
    # The labels record the handoff before anyone is told; a failed write sends nothing.
    phase: Phase = "implement" if back else "review"
    assign(record["brief"], phase, recipient)
    if back:
        partner = live_name(record["slot"], recipient)
        failed = deliver([(partner, implementer_message(pr, failures))])
    else:
        failed = hand_to_reviewers(record, me, pr, failures)
    if failed:
        raise RuntimeError(
            "Handoff incomplete; failed sends: "
            + "; ".join(failed)
            + ". "
            + labels_stay(phase, recipient)
            + " Report blocked with these errors, or rerun turn after fixing them."
        )
    print("End your turn now.")


# --- Retirement and stop ---------------------------------------------------


def retirement_paths(allocation: Allocation) -> tuple[Path, Path, Path, Path]:
    """The allocation's directories, refused unless the record names its canonical
    allocation and no path leaves the harness root or passes through a symlink."""
    paths = allocation_paths(allocation["id"])
    if Path(allocation["root"]) != paths[0]:
        raise RuntimeError(
            f"{allocation['name']}: recorded allocation {allocation['root']} is not "
            f"{paths[0]}; preserved"
        )
    return checked_paths(allocation["id"])


# stop's next step when a recorded pane holds a client it cannot confirm.
STOP_STEP = (
    "Nothing was stopped. The operator inspects the pane and reruns stop once that client "
    "has exited."
)


def live_clients(record: Record) -> dict[str, Allocation]:
    """The recorded clients running in their panes; any other client in a recorded pane
    refuses."""
    return {e: a for e, a in record["agents"].items() if checked_client(record, a, STOP_STEP)}


def port_in_use(port: int) -> bool:
    """Whether anything listens on the port; anything but a refused connection counts."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        return probe.connect_ex(("127.0.0.1", port)) != errno.ECONNREFUSED


def checked_paths(ident: str) -> tuple[Path, Path, Path, Path]:
    """The allocation's directories, refused if a path leaves the harness root or passes
    through a symlink."""
    paths = allocation_paths(ident)
    trusted = conf.harness_root()
    for directory in paths:
        if directory.exists() or directory.is_symlink():
            contained(directory, trusted)
    return paths


def remove_if_empty(directory: Path) -> None:
    """Remove an empty directory; one that holds anything stays."""
    try:
        directory.rmdir()
    except FileNotFoundError:
        pass
    except OSError as error:
        if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
            raise


class Retired(TypedDict):
    """`state/<id>/retired.json`: what stop retired and what cleanup last did with it.

    `files` is pending, deleted, `kept: <why>` or `failed: <paths>`; `databases` is pending,
    dropped, `refused: <why>` or `kept: <why>`.
    """

    id: str
    issue: str
    abandoned: bool
    db_suffix: str
    files: str
    databases: str
    orphans: list[str]
    report: NotRequired[str]


ABANDONED = "brief closed without a merged PR (stop --abandon)"


def read_retired(path: Path) -> Retired:
    fields = object_fields(json.loads(path.read_text()), str(path))
    for key in ("id", "issue", "db_suffix", "files", "databases"):
        require_type(fields.get(key), str, f"{path}: {key}")
    if not isinstance(fields.get("abandoned"), bool):
        raise ValueError(f"{path}: abandoned must be true or false; preserved")
    return cast(Retired, fields)


def retired_notes() -> dict[str, Retired]:
    """Every readable retirement note by allocation ID. An unreadable one, such as a note an
    older release wrote, is reported and skipped: it never blocks cleanup of the others."""
    notes: dict[str, Retired] = {}
    for path in sorted(conf.state_dir().glob("*/retired.json")):
        try:
            notes[path.parent.name] = read_retired(path)
        except (OSError, ValueError) as error:
            print(f"{path}: unreadable retired.json: {error}; skipped")
    return notes


def write_retired(path: Path, note: Retired) -> None:
    write_file(path, json.dumps(note, indent=2, sort_keys=True) + "\n")


def retire(record: Record, abandon: bool) -> None:
    """Write each allocation's retirement note, which cleanup reads once the record is gone.
    stop wrote it only after its merge check passed, or for a standalone design team or an
    abandoned brief."""
    for allocation in record["agents"].values():
        note = Retired(
            id=allocation["id"],
            issue=record["brief"],
            abandoned=abandon,
            db_suffix=allocation["db_suffix"],
            files="pending",
            databases="pending",
            orphans=[],
        )
        write_retired(retirement_paths(allocation)[3] / "retired.json", note)


# What each Git check finds when its output is not empty. Only origin counts as published.
GIT_CHECKS = (
    (("status", "--porcelain"), "uncommitted or untracked files"),
    (("rev-list", "HEAD", "--branches", "--not", "--remotes=origin"), "commits not on origin"),
    (("stash", "list"), "stashed changes"),
)


def unpublished_work(project: Path) -> str:
    """Why Git cannot show that the clone holds nothing beyond origin, or "" when it can.

    Fetch with prune first, so origin's refs are current. A missing or unreadable
    repository, a failed command and a timeout are reasons, never an empty result. Commands
    run from the state directory with hooks and fsmonitor off; the rest of the clone's own
    Git configuration still applies, within the accepted risk of worker authority.
    """
    git_dir = project / ".git"
    if git_dir.is_symlink() or not git_dir.is_dir():
        return "project has no Git repository"
    git = ["git", f"--git-dir={git_dir}", f"--work-tree={project}"]
    git += ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
    timeout = conf.settings()["timeouts"]["launch_seconds"]
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    for args, finding in ((("fetch", "--prune", "--quiet", "origin"), ""), *GIT_CHECKS):
        try:
            result = execute(
                [*git, *args], cwd=conf.state_dir(), env=env, timeout=timeout, input_text=""
            )
        except subprocess.TimeoutExpired:
            return f"git {args[0]} did not finish within {timeout} s; incomplete"
        if result.returncode:
            return f"git {args[0]} failed: {result.stderr.strip()[-500:]}"
        if finding and result.stdout.strip():
            return f"{finding}: {'; '.join(result.stdout.splitlines()[:3])}"
    return ""


def delete_allocation(ident: str) -> str:
    """Delete the whole allocation unless its clone holds work Git cannot show is on origin;
    then only `state/<id>/retired.json` remains. A project never cloned into is empty, so
    it needs no Git check. Return the files outcome for the note."""
    root, project, _, config = checked_paths(ident)
    remove_if_empty(project)
    if project.exists():
        problem = unpublished_work(project)
        if problem:
            return f"kept: {problem}"
    remaining: list[str] = []
    if root.exists():
        shutil.rmtree(root, onexc=lambda _call, path, _error: remaining.append(str(path)))
    if remaining:
        # The first paths name the cause; a full list can run to thousands.
        shown = ", ".join(remaining[:10])
        return f"failed: could not delete {len(remaining)} paths, including {shown}"
    (config / "bootstrap.json").unlink(missing_ok=True)
    return "deleted"


def psql_command() -> list[str]:
    """The trusted psql argv: no FORCE, no project compose or configuration."""
    return [*conf.settings()["team"]["psql"], "-X", "-v", "ON_ERROR_STOP=1"]


def database_names() -> tuple[list[str], str]:
    """Every database name, or no names and why psql could not list them."""
    timeout = conf.settings()["timeouts"]["launch_seconds"]
    query = [*psql_command(), "-Atc", "SELECT datname FROM pg_database"]
    try:
        listing = execute(query, cwd=conf.state_dir(), timeout=timeout)
    except subprocess.TimeoutExpired:
        return [], f"psql did not list databases within {timeout} s; incomplete"
    if listing.returncode:
        return [], f"psql could not list databases: {listing.stderr.strip()}"
    return listing.stdout.splitlines(), ""


def drop_generation(namespace: str, names: list[str]) -> tuple[str, list[str]]:
    """Drop every listed database in the generation's namespace, recorded or not, with its
    numbered partitions. Without FORCE, a remaining connection makes PostgreSQL refuse a
    drop; the rest go on. Return the databases outcome and the names dropped."""
    timeout = conf.settings()["timeouts"]["launch_seconds"]
    team = conf.settings()["team"]
    dropped: list[str] = []
    refused: list[str] = []
    for db in (name for name in names if namespace_of(team, name) == namespace):
        statement = 'DROP DATABASE "' + db.replace('"', '""') + '"'
        try:
            result = execute(
                [*psql_command(), "-c", statement], cwd=conf.state_dir(), timeout=timeout
            )
        except subprocess.TimeoutExpired:
            refused.append(f"{db}: no answer within {timeout} s; incomplete")
            continue
        if result.returncode:
            refused.append(f"{db}: {result.stderr.strip()}")
        else:
            dropped.append(db)
    return (f"refused: {'; '.join(refused)}" if refused else "dropped"), dropped


def orphans(notes: dict[str, Retired], live: list[Allocation], names: list[str]) -> list[str]:
    """Allocation folders and namespace databases that no live record and no retirement
    owns, and retirements whose suffix names no generation. They are reported, never
    deleted."""
    team = conf.settings()["team"]
    owners = {*notes, *(a["id"] for a in live)}
    root = conf.harness_root() / "allocations"
    found = [str(path) for path in sorted(root.glob("g*")) if path.name not in owners]
    suffixes = [n["db_suffix"] for n in notes.values()] + [a["db_suffix"] for a in live]
    spaces = {namespace_of(team, suffix) for suffix in suffixes}
    for ident, note in notes.items():
        if namespace_of(team, note["db_suffix"]) is None:
            found.append(f"retirement {ident}: suffix {note['db_suffix']} names no generation")
    for name in names:
        space = namespace_of(team, name)
        if space is not None and space not in spaces:
            found.append(f"database {name}")
    return found


def kept_because(ident: str, note: Retired, live: list[Allocation]) -> str:
    """Why cleanup must keep this retired allocation, or "" when it may proceed. stop's
    merge check already passed for every retirement it did not abandon."""
    if any(a["id"] == ident for a in live):
        return "a live record names this allocation"
    if note["abandoned"]:
        return ABANDONED
    return ""


def delete_allocations(mine: dict[str, Retired], live: list[Allocation]) -> dict[str, list[str]]:
    """Delete each eligible allocation's folder and record the files outcome. Return the
    eligible allocations by generation namespace, whose databases cleanup drops."""
    team = conf.settings()["team"]
    generations: dict[str, list[str]] = {}
    for ident, note in mine.items():
        reason = kept_because(ident, note, live)
        if reason:
            note["files"] = f"kept: {reason}"
            if note["abandoned"]:
                note["databases"] = f"kept: {reason}"
            continue
        note["files"] = delete_allocation(ident)
        namespace = namespace_of(team, note["db_suffix"])
        if namespace is None:
            note["databases"] = f"kept: suffix {note['db_suffix']} names no generation"
        else:
            generations.setdefault(namespace, []).append(ident)
    return generations


def clean_up(issue: str) -> None:
    """Delete the issue's retired allocations whose clones hold nothing unpublished, drop
    their generations' databases, and print and record what was deleted, kept and found
    unowned. The orphan scan runs before anything is deleted. The caller holds the store
    lock."""
    live = [a for record in records().values() for a in record["agents"].values()]
    notes = retired_notes()
    mine = {ident: note for ident, note in notes.items() if note["issue"] == issue}
    if not mine:
        print(f"#{issue}: no retired allocations; nothing removed")
        return
    names, problem = database_names()
    unowned = orphans(notes, live, names)
    if problem:
        unowned.append(f"databases not checked: {problem}")
    for namespace, idents in delete_allocations(mine, live).items():
        dropped: list[str] = []
        status = f"refused: {problem}"
        if not problem:
            status, dropped = drop_generation(namespace, names)
        line = f"Databases {namespace}: dropped {', '.join(dropped) or 'none'}"
        print(line if status == "dropped" else f"{line}; {status}")
        for ident in idents:
            mine[ident]["databases"] = status
    for ident, note in mine.items():
        note["orphans"] = unowned
        write_retired(conf.state_dir() / ident / "retired.json", note)
        print(f"{ident}: files {note['files']}; databases {note['databases']}")
    for orphan in unowned:
        print(f"Orphan, not deleted: {orphan}")


def cleanup(issue: str) -> None:
    """Rerun cleanup for an issue's retired allocations: after an interrupted run, a kept
    clone whose work is now published, or an old generation."""
    with store_lock():
        clean_up(issue)


def list_retained() -> None:
    """List each retired allocation that still has files or databases, with cleanup's last
    result. Deletes nothing; `cleanup <issue>` reruns cleanup."""
    found = False
    for ident, note in retired_notes().items():
        root = allocation_paths(ident)[0]
        if not root.exists() and note["databases"] == "dropped":
            continue
        found = True
        print(
            f"{note['id']} (#{note['issue']}): {root}; files: {note['files']}; "
            f"databases {note['db_suffix']}: {note['databases']}"
        )
    if not found:
        print("No retained allocations")


def stop_brief(brief: str, *, abandon: bool = False) -> None:
    """Stop a team's recorded clients and Dexter daemons, release its slot, then clean up.

    A brief must be closed by a PR merged into main before anything stops, unless it is a
    standalone design team or the operator abandons it. A conflict, a failed stop or a busy
    port keeps the reservation, so stop can run again. Once the record is gone, cleanup
    deletes each allocation whose clone holds nothing unpublished and drops the team's
    generation's databases; an abandoned team keeps everything.
    """
    with store_lock():
        record = record_for(brief)
        if record is None:
            print(f"#{brief}: no allocation record; nothing removed")
            return
        # A brief still in progress is never interrupted: a wrong issue number stops nothing.
        if record["kind"] == "brief" and not abandon and not merged_brief(brief):
            command = harness_command("team.py", "stop", brief, "--abandon")
            raise RuntimeError(
                f"#{brief} is not closed by a PR merged into main. Nothing was stopped; the "
                "record, databases, files and reservation are kept. If the brief was closed "
                f"without a merged PR, the operator runs {command}; until then the slot stays "
                "taken: agent/teams/README.md#retire-a-brief-closed-without-a-merged-pr"
            )
        require_only_recorded_panes(record)
        paths = [retirement_paths(a) for a in record["agents"].values()]
        roots = [root for root, *_ in paths]
        names = [a["name"] for a in record["agents"].values()]
        panes = frozenset(a["pane"] for a in record["agents"].values())
        refuse_foreign_owner(roots, names, panes)
        replace_labels(brief, WORKFLOW, [])  # a failed write stops nothing; rerun stop
        present = live_clients(record)
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
        retire(record, abandon)
        record_path(record["slot"]).unlink()
        print(f"#{brief}: slot {record['slot']} released")
        clean_up(brief)


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
    started = "running" if allocation["submission"] == SUBMITTED else "startup incomplete"
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
    write_file(path, json.dumps(launch) + "\n")
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
    """Print every allocation record with each client's live Herdr state and the dispatcher's.

    The dispatcher has no file tools, so this also prints the capacity and the entries it
    may name on a brief."""
    agents = {a["pane_id"]: a for a in herdr("agent", "list")["agents"]}
    named = {a.get("name"): a for a in agents.values()}
    print(dispatcher_status(named.get("dispatcher")))
    config = conf.settings()
    print(f"slots: {config['team']['max_teams']}")
    for entry, spec in sorted(config["agents"].items()):
        print(f"entry {entry}: {spec['role']}, {spec['kind']}, {spec['model']}")
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


def recorded_client(brief: str, entry: str) -> Allocation:
    """The brief's recorded client, refused unless its pane holds that same client.

    The target is a recorded role, never a pane: an unrecorded or replaced client is refused.
    """
    record = record_for(brief)
    if record is None:
        raise RuntimeError(f"Brief #{brief} has no allocation record")
    allocation = record["agents"].get(entry)
    if allocation is None:
        raise RuntimeError(f"Brief #{brief} has no launched {entry}")
    if checked_client(record, allocation, "Nothing was sent.") is None:
        raise RuntimeError(f"{allocation['name']} is not running in {allocation['pane']}")
    return allocation


def send_prompt(allocation: Allocation, text: str) -> None:
    """Any failure of the prompt call, including Herdr's own timeout, may come after the text
    reached the client, so the error says delivery is unknown and not to resend blindly."""
    try:
        herdr("agent", "prompt", allocation["name"], text)
    except (subprocess.TimeoutExpired, RuntimeError, ValueError) as error:
        raise RuntimeError(
            f"Prompt to {allocation['name']} failed ({error}); it may have been delivered. "
            "Read the agent's records before sending it again."
        ) from error
    print(f"Prompted {allocation['name']}")


def prompt_agent(brief: str, entry: str, text: str) -> None:
    """Send text to a recorded client of the brief; the issue's labels are unchanged."""
    send_prompt(recorded_client(brief, entry), text)


def hand_off(brief: str, entry: str, text: str, phase: Phase) -> None:
    """Make the recorded client the brief's coordinating owner in this phase, then send
    the text. A failed label write sends nothing; a failed send keeps the labels."""
    allocation = recorded_client(brief, entry)
    assign(brief, phase, entry)
    try:
        send_prompt(allocation, text)
    except RuntimeError as error:
        raise RuntimeError(f"{error} {labels_stay(phase, entry)}") from error


def cli() -> None:
    conf.configure()
    args = sys.argv[1:]
    usage = (
        "Usage: agent/teams/team.py start <brief> | design <issue> <entry> | "
        "turn <pr> <entry> | review <pr> <entry> | reset <issue> <entry> | stop <issue> | "
        "stop <issue> --abandon | cleanup <issue> | retained | status. Only the operator runs "
        "reset and stop --abandon, which retires a brief closed without a merged PR and "
        "keeps its files and databases."
    )
    if args == ["status"]:
        status()
        return
    if args == ["retained"]:
        list_retained()
        return
    if len(args) < 2 or not args[1].isdecimal():
        raise RuntimeError(usage)
    named = len(args) == 3 and re.fullmatch(ENTRY, args[2]) is not None
    by_issue = {"start": start, "cleanup": cleanup}
    if args[0] in by_issue and len(args) == 2:
        by_issue[args[0]](args[1])
    elif args[0] == "stop" and args[2:] in ([], ["--abandon"]):
        stop_brief(args[1], abandon=args[2:] == ["--abandon"])
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
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        # A TypeError or KeyError is a harness bug: its traceback stays visible.
        print(f"team: {error}", file=sys.stderr)
        sys.exit(1)
