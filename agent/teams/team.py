#!/usr/bin/env python3
"""Pair lifecycle in Herdr: start, hand over and stop one developer-tester pair per issue."""

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
from collections.abc import Sequence
from pathlib import Path
from typing import NotRequired, TypedDict, cast


class Role(TypedDict):
    kind: str
    model: str
    effort: str
    port_offset: int
    db_suffix: str


class TeamSettings(TypedDict):
    max_teams: int
    workspace_prefix: str
    port_base: int
    port_stride: int
    postgres_port: int
    db_suffix_prefix: str


class Config(TypedDict):
    team: TeamSettings
    timeouts: dict[str, int]
    launch: dict[str, str]
    roles: dict[str, Role]


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
    workspace_id: str
    label: str
    name: str
    agent: str
    agent_status: str
    cwd: str
    foreground_cwd: str


class HerdrResult(TypedDict):
    pane: Entity
    root_pane: Entity
    workspace: Entity
    agent: Entity
    panes: list[Entity]
    workspaces: list[Entity]
    agents: list[Entity]
    process_info: ProcessInfo


ProcessRows = dict[int, tuple[int, str]]
ROLES = ("dev", "test")
ROLE_TITLES = {"dev": "developer", "test": "tester"}
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
    """Refuse before Git administration when this process cannot write main's .git.

    Create a file to probe: mode bits do not show a client sandbox's write denial.
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
    for key in Entity.__annotations__:
        if key in fields and fields[key] is not None:
            require_type(fields[key], str, f"{label}.{key}")


def object_list(value: object, label: str) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list; received {value!r}")
    return [object_fields(item, label) for item in cast(list[object], value)]


def parse_herdr(output: str) -> HerdrResult:
    envelope = object_fields(json.loads(output), "Herdr response")
    if "error" in envelope:
        raise RuntimeError(str(envelope["error"]))
    result = object_fields(envelope.get("result"), "Herdr result")
    for key in ("agent", "pane", "root_pane", "workspace"):
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


def processes() -> ProcessRows:
    # Parent links, not process groups: Expert engines can create their own groups.
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
    for key in ("workspace_prefix", "db_suffix_prefix"):
        require_type(settings.get(key), str, f"{path}: team.{key}")
    object_fields(fields.get("timeouts"), f"{path}: timeouts")
    policies = object_fields(fields.get("launch"), f"{path}: launch")
    for key in ("codex_approval", "claude_permission_mode"):
        require_type(policies.get(key), str, f"{path}: launch.{key}")
    roles = object_fields(fields.get("roles"), f"{path}: roles")
    for name in ROLES:
        role = object_fields(roles.get(name), f"{path}: roles.{name}")
        for key in ("kind", "model", "effort", "db_suffix"):
            require_type(role.get(key), str, f"{path}: roles.{name}.{key}")
        require_type(role.get("port_offset"), int, f"{path}: roles.{name}.port_offset")


def validate_settings(path: Path, value: Config) -> None:
    for key in (
        "launch_seconds",
        "shutdown_seconds",
        "shell_seconds",
        "checks_minutes",
        "dexter_startup_seconds",
    ):
        if type(value["timeouts"][key]) is not int or value["timeouts"][key] <= 0:
            raise RuntimeError(f"{path}: timeouts.{key} must be a positive integer")
    if value["team"]["max_teams"] < 1:
        raise RuntimeError(f"{path}: team.max_teams must be positive")
    for name in ROLES:
        if value["roles"][name]["kind"] not in ("codex", "claude"):
            raise RuntimeError(f"{path}: invalid role {name}")


def validate_allocations(path: Path, value: Config) -> None:
    ports: set[int] = set()
    stems: list[str] = []
    for n in range(1, value["team"]["max_teams"] + 1):
        for role in ROLES:
            spec = value["roles"][role]
            port = (
                value["team"]["port_base"] + n * value["team"]["port_stride"] + spec["port_offset"]
            )
            stem = value["team"]["db_suffix_prefix"] + str(n) + spec["db_suffix"]
            if port in ports or not 1 <= port <= 65535:
                raise RuntimeError(f"{path}: overlapping or invalid test ports")
            if any(
                re.fullmatch(re.escape(a) + r"[0-9]*", b)
                for a, b in [(stem, x) for x in stems] + [(x, stem) for x in stems]
            ):
                raise RuntimeError(f"{path}: overlapping database suffix/partition allocation")
            ports.add(port)
            stems.append(stem)


def pane_roles(workspace: Entity, names: list[str]) -> dict[str, Entity]:
    result: dict[str, Entity] = {}
    for pane in herdr("pane", "list", "--workspace", workspace["workspace_id"])["panes"]:
        label = pane.get("label")
        if label not in names or label in result:
            raise RuntimeError(f"Unexpected or duplicate pane {pane['pane_id']}; preserved")
        result[label] = pane
    return result


def git(*args: str | Path, root: Path | None = None) -> str:
    return run("git", "-C", root or main, *args)


def pair_workspaces() -> dict[int, tuple[str, Entity]]:
    """Live pair workspaces by slot; each label names its slot and issue."""
    pattern = re.escape(cfg["team"]["workspace_prefix"]) + r"-([0-9]+)-([0-9]+)"
    pairs: dict[int, tuple[str, Entity]] = {}
    for workspace in herdr("workspace", "list")["workspaces"]:
        match = re.fullmatch(pattern, workspace.get("label") or "")
        if not match:
            continue
        slot = int(match.group(1))
        if slot in pairs:
            raise RuntimeError(f"Ambiguous workspaces for slot {slot}; preserved")
        pairs[slot] = (match.group(2), workspace)
    return pairs


def find_slot(issue: str) -> tuple[int, Entity | None]:
    """The slot already holding this issue, else the first free one."""
    pairs = pair_workspaces()
    for slot, (owner, workspace) in pairs.items():
        if owner == issue:
            return slot, workspace
    for slot in range(1, cfg["team"]["max_teams"] + 1):
        if slot not in pairs:
            return slot, None
    raise RuntimeError(f"No free slot: team.max_teams is {cfg['team']['max_teams']}")


def bound_command(binary: Path, root: Path, sources: Path | str) -> str:
    """The worktree's Dexter command: the one place naming binary, root and sources."""
    return (
        "#!/bin/sh\n"
        f"export DEXTER_ELIXIR_LIB_ROOT={shlex.quote(str(sources))}\n"
        f"exec {shlex.quote(str(binary))} --root {shlex.quote(str(root))}"
        ' "$@"\n'
    )


def warm_up_query(startup_seconds: int) -> list[str]:
    """Bound-command arguments that start the daemon and wait for its index."""
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


def role_env(role: str, slot: int, worktree: Path) -> dict[str, str]:
    """One client's environment: its own database and port, the pair's worktree tools."""
    spec, team = cfg["roles"][role], cfg["team"]
    config = Path(os.environ.get("TIPS_TEAM_CONFIG", main / "agent/teams/config.toml")).resolve()
    env = {
        "PGPORT": str(team["postgres_port"]),
        "TIPS_DB_SUFFIX": team["db_suffix_prefix"] + str(slot) + spec["db_suffix"],
        "TIPS_TEST_PORT": str(team["port_base"] + team["port_stride"] * slot + spec["port_offset"]),
        "MIX_ENV": "test",
        "TIPS_CHECK_TIMEOUT_SECONDS": str(cfg["timeouts"]["checks_minutes"] * 60),
        "TIPS_TEAM_CONFIG": str(config),
        # Provider settings are read by path from the main checkout; nothing is copied.
        "TIPS_PROVIDER_ENV_FILE": str(main / ".env"),
        "TIPS_DEXTER": str(worktree / ".dexter/dexter.sh"),
    }
    if spec["kind"] == "codex":
        # Codex's sandbox cannot write the shared Hex cache in the home directory.
        env["HEX_HOME"] = str(worktree / "tmp/hex")
    return env


def checkout(issue: str, worktree: Path) -> bool:
    """Add the task worktree from fetched origin/main; return whether it is new."""
    branch = "task/" + issue
    if worktree.exists():
        if (
            Path(git("rev-parse", "--show-toplevel", root=worktree)) != worktree
            or git("branch", "--show-current", root=worktree) != branch
        ):
            raise RuntimeError(f"Not a worktree on {branch}: {worktree}")
        return False
    git("fetch", "origin")
    if git("branch", "--list", branch):
        git("worktree", "add", worktree, branch)
    else:
        git("worktree", "add", "--no-track", "-b", branch, worktree, "origin/main")
    return True


def link_skills(link: Path, shared: Path) -> None:
    if link.is_symlink() and os.readlink(link) == str(shared):
        return
    if link.exists() and not link.is_symlink():
        raise RuntimeError(f"Refusing to replace existing skills: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to(shared)


def prepare_index(worktree: Path, wrapper: Path, slot: int, fetch: bool) -> None:
    """Fetch a new checkout's locked dependencies, start Dexter and reconcile its index."""
    # A Codex role's environment wins: its sandbox needs the Hex cache inside the worktree.
    role = next((r for r in ROLES if cfg["roles"][r]["kind"] == "codex"), ROLES[0])
    env = {**os.environ, **role_env(role, slot, worktree)}
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


def prepare_worktree(issue: str, worktree: Path, slot: int) -> None:
    """Create or reuse the pair's worktree and prepare it once for both clients."""
    # Preflight before any change: a refusal here leaves no worktree behind.
    binary, skills = dexter_binary(), main / ".agents/skills"
    if not skills.is_dir():
        raise RuntimeError("Shared skills directory is missing.")
    sources = elixir_sources(worktree if worktree.is_dir() else main)
    new = checkout(issue, worktree)
    wrapper = worktree / ".dexter/dexter.sh"
    files = {
        wrapper: bound_command(binary, worktree, sources),
        worktree / ".dexter/.gitignore": "*\n",
    }
    if any(cfg["roles"][role]["kind"] == "codex" for role in ROLES):
        files[worktree / ".codex/config.toml"] = CODEX_CONFIG
    for path, content in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_text() != content:
            path.write_text(content)
    wrapper.chmod(0o755)
    link_skills(worktree / ".agents/skills", skills)
    # A fetch that failed last time left no dependencies: fetch again.
    prepare_index(worktree, wrapper, slot, fetch=new or not (worktree / "deps").is_dir())


def refuse_foreign_owner(worktree: Path, names: list[str]) -> None:
    """Only the assigned pair may work in the task worktree."""
    for agent in herdr("agent", "list")["agents"]:
        if agent.get("name") not in names and pane_occupant(agent["pane_id"])[0] == worktree:
            owner = agent.get("name") or agent["pane_id"]
            raise RuntimeError(f"Conflicting live agent in {worktree}: {owner}")


def open_panes(label: str, workspace: Entity | None, names: list[str]) -> dict[str, Entity]:
    """Reuse the pair's workspace or create it, with one labelled shell pane per role."""
    if workspace:
        panes = pane_roles(workspace, names)
    else:
        created = herdr("workspace", "create", "--cwd", str(main), "--label", label, "--no-focus")
        first = created["root_pane"]
        herdr("pane", "rename", first["pane_id"], names[0])
        panes = {names[0]: first}
    for name in names:
        if name not in panes:
            beside = next(iter(panes.values()))["pane_id"]
            pane = herdr(
                "pane", "split", beside, "--direction", "right", "--cwd", str(main), "--no-focus"
            )["pane"]
            herdr("pane", "rename", pane["pane_id"], name)
            panes[name] = pane
    return panes


def enter(pane: str, worktree: Path, env: dict[str, str]) -> None:
    """Move the pane's shell into the worktree with the client's environment."""
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


def brief(role: str, name: str, issue: str, wrapper: Path) -> str:
    # A relaunched client gets this brief too, so it finds the turn instead of assuming it.
    # The binary is shared by every checkout and the guide is not, so the binary's own
    # help is the contract a lagging checkout can still trust.
    return (
        f"You are {name}, the {ROLE_TITLES[role]} for issue #{issue}. "
        f"Read agent/teams/README.md, then the issue with gh issue view {issue}. "
        "Find whose turn it is with the README restart rule. If it is yours, do your next "
        "common-path step; otherwise end your turn and wait for your partner's ring. "
        "Before reading Elixir code, load the skills AGENTS.md requires. "
        "For Elixir navigation, use Dexter before text tools. "
        f"TIPS_DEXTER={wrapper} is bound to this worktree; run it via the shell. "
        'Read "$TIPS_DEXTER" query --help and "$TIPS_DEXTER" lookup --help once; '
        "their syntax and output take precedence over a lagging checkout guide. "
        'After fetching or changing dependencies, run "$TIPS_DEXTER" reindex. '
        "Do not start another Elixir language server. Freshness is unverified; "
        "empty results are not proof of absence. Do not stop the shared daemon when "
        "this agent exits, and do not run git clean -x: it deletes the bound command "
        "and the index while the daemon may still run."
    )


def client_args(role: str, prompt: str, worktree: Path) -> list[str]:
    spec, policies = cfg["roles"][role], cfg["launch"]
    if spec["kind"] == "codex":
        args = ["-a", policies["codex_approval"], "-C", str(worktree)]
        if spec["model"]:
            args += ["-m", spec["model"]]
        return [*args, "-c", "model_reasoning_effort=" + json.dumps(spec["effort"]), prompt]
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
    return args


def launch(role: str, name: str, pane: str, issue: str, worktree: Path, slot: int) -> None:
    """Start one client in its pane, or keep the one already running there."""
    kind = cfg["roles"][role]["kind"]
    root, live = pane_occupant(pane)
    if live:
        agent = herdr("agent", "get", pane)["agent"]
        if agent.get("name") != name or agent.get("agent") != kind or root != worktree:
            raise RuntimeError(f"{pane}: conflicting client; preserved")
        print(f"Already running: {name} ({agent.get('agent_status')})")
        return
    enter(pane, worktree, role_env(role, slot, worktree))
    prompt = brief(role, name, issue, worktree / ".dexter/dexter.sh")
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
        *client_args(role, prompt, worktree),
    )
    started = herdr("agent", "get", pane)["agent"]
    if (
        pane_occupant(pane) != (worktree, True)
        or started.get("agent") != kind
        or started.get("name") != name
        or started.get("agent_status") in ("blocked", "unknown")
    ):
        raise RuntimeError(f"{name} started in an unexpected state or root; inspect {pane}")
    if kind == "claude":
        # Claude holds the brief as its system prompt and waits; Codex receives it as input.
        herdr("agent", "prompt", name, "Begin.")
    print(f"Launched {name}: {kind} in {worktree}")


def start(issue: str) -> None:
    """Launch a developer and a tester for one issue in one prepared worktree."""
    if Path.cwd() != main:
        raise RuntimeError(f"Run from the main checkout: {main}")
    require_git_admin(main / ".git")
    slot, workspace = find_slot(issue)
    names = [f"team-{slot}-{role}" for role in ROLES]
    worktree = main / ".worktrees" / issue
    refuse_foreign_owner(worktree, names)
    prepare_worktree(issue, worktree, slot)
    label = f"{cfg['team']['workspace_prefix']}-{slot}-{issue}"
    panes = open_panes(label, workspace, names)
    for role, name in zip(ROLES, names, strict=True):
        launch(role, name, panes[name]["pane_id"], issue, worktree, slot)
    print(f"Issue {issue}: pair in slot {slot}, {worktree}")


def checkout_problem(head: str) -> str | None:
    """Why this checkout is not the pushed PR head, or None."""
    here = Path.cwd()
    if git("status", "--porcelain", "--untracked-files=all", root=here):
        return "The worktree has uncommitted or untracked files."
    local = git("rev-parse", "HEAD", root=here)
    if local != head:
        return f"HEAD is {local}, not the PR head {head}."
    return None


def turn(pr: str, recipient: str) -> None:
    """Hand the shared worktree to the partner and ring it."""
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane:
        raise RuntimeError("HERDR_PANE_ID is not set; run turn from your own pair pane")
    me = herdr("agent", "get", pane)["agent"].get("name") or ""
    match = re.fullmatch(r"team-([0-9]+)-(dev|test)", me)
    if not match or match.group(2) == recipient:
        raise RuntimeError(
            f"turn hands over to the other pair agent; this pane is {me or 'unnamed'}"
        )
    view = json.loads(run("gh", "pr", "view", pr, "--json", "headRefOid,url"))
    head, url = str(view["headRefOid"]), str(view["url"])
    problem = checkout_problem(head)
    if recipient == "test":
        if problem:
            raise RuntimeError(f"{problem} Commit and push, then hand over.")
        message = (
            f"Your turn: review {url} at {head}. Apply AGENTS.md Tests and GitHub and the "
            "README PR review record; judge the test changes as a set. Submit your findings "
            f"or publish the approval, then run agent/teams/team.py turn {pr} dev. "
            "Do not wait for CI."
        )
    else:
        message = (
            f"Your turn on {url}: run agent/teams/pr_review.py list {pr}. If this head is "
            "approved, do README step 9: confirm the merge, then ring the dispatcher done. "
            "Otherwise answer the findings and hand back; if stuck, apply README Stuck."
        )
        if problem:
            # Handing back never refuses: only the developer can repair the checkout.
            message += f" Fix the checkout first: {problem}"
            print(f"Reported to the developer: {problem}")
    partner = f"team-{match.group(1)}-{recipient}"
    herdr("agent", "prompt", partner, message)
    print(f"Rang {partner}. Stop using this worktree, build and database; end your turn now.")


def stop_pair(issue: str) -> None:
    """Retire a pair whose work is clean and merged; preserve everything otherwise."""
    found = [(slot, ws) for slot, (owner, ws) in pair_workspaces().items() if owner == issue]
    if not found:
        print(f"Issue {issue}: no pair workspace; nothing removed")
        return
    slot, workspace = found[0]
    panes = pane_roles(workspace, [f"team-{slot}-{role}" for role in ROLES])
    roots = owned_worktrees(panes)
    worktree = main / ".worktrees" / issue
    if worktree.is_dir():
        roots.add(worktree)
    check_shared_owners(roots, panes)
    if roots:
        require_git_admin(main / ".git")
        git("fetch", "origin")
    check_worktrees(roots)
    for pane in panes.values():
        stop(pane["pane_id"], pane_occupant(pane["pane_id"])[0])
    check_worktrees(roots)
    check_shared_owners(roots, panes)
    retire(roots, slot)
    herdr("workspace", "close", workspace["workspace_id"])
    print(f"Issue {issue}: pair retired; main checkout status follows")
    print(git("status", "--short") or "Main checkout clean")


def retire(roots: set[Path], slot: int) -> None:
    """Stop each worktree's daemon, drop the pair's databases, remove worktrees and branches."""
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
    drop_databases(slot)
    for root in sorted(roots):
        branch = git("branch", "--show-current", root=root)
        git("worktree", "remove", root)
        # check_worktrees proved the branch merged into fetched origin/main; -d would
        # compare against the main checkout's own, possibly stale, branch.
        if branch.startswith("task/"):
            git("branch", "-D", branch)


def check_shared_owners(roots: set[Path], panes: dict[str, Entity]) -> None:
    """Do not retire a worktree still used by an agent outside this pair."""
    owned_panes = {pane["pane_id"] for pane in panes.values()}
    for agent in herdr("agent", "list")["agents"]:
        pane = agent["pane_id"]
        if pane not in owned_panes and pane_occupant(pane)[0] in roots:
            raise RuntimeError(f"Worktree still shared with {agent.get('name') or pane}; preserved")


def owned_worktrees(panes: dict[str, Entity]) -> set[Path]:
    roots: set[Path] = set()
    # Validate every pane before stopping any client.
    for name, pane in panes.items():
        root = pane_occupant(pane["pane_id"])[0]
        if root != main and (
            root.parent != main / ".worktrees"
            or Path(
                git("rev-parse", "--path-format=absolute", "--git-common-dir", root=root)
            ).resolve()
            != main / ".git"
        ):
            raise RuntimeError(f"{pane['pane_id']}: unexpected worktree {root}; preserved")
        if pane.get("agent"):
            agent = herdr("agent", "get", pane["pane_id"])["agent"]
            if agent.get("name") != name:
                raise RuntimeError(f"{pane['pane_id']}: conflicting owner; preserved")
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


def drop_databases(slot: int) -> None:
    prefix = cfg["team"]["db_suffix_prefix"] + str(slot)
    stems = ["tips_test" + prefix + cfg["roles"][role]["db_suffix"] for role in ROLES]
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
    """Graceful client exit; raise on uncertainty. Caller must preserve the checkout."""
    configure()
    stop(pane, root)


def cli() -> None:
    configure()
    args = sys.argv[1:]
    usage = "Usage: agent/teams/team.py start <issue> | turn <pr> dev|test | stop <issue>"
    if len(args) < 2 or not args[1].isdecimal():
        raise RuntimeError(usage)
    if args[0] == "start" and len(args) == 2:
        start(args[1])
    elif args[0] == "stop" and len(args) == 2:
        stop_pair(args[1])
    elif args[0] == "turn" and len(args) == 3 and args[2] in ROLES:
        turn(args[1], args[2])
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
