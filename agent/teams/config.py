"""Shared types and constants, the loaded configuration and the harness root's paths.

configure() is the only writer of `cfg` and `main`. Read them through this module
(`import config as conf`), never by name: configure() rebinds them.
"""

import json
import os
import re
import tempfile
import tomllib
from pathlib import Path
from typing import Literal, NotRequired, TypedDict, cast, get_args

from commands import object_fields, require_type, run


class AgentSpec(TypedDict):
    role: str
    kind: str
    model: str
    effort: str
    persona: NotRequired[str]
    port_offset: int
    db_suffix: str


class GitHubSettings(TypedDict):
    repository: str
    # Project number -> field names the dispatcher may set.
    projects: dict[str, list[str]]


class TeamSettings(TypedDict):
    clone_url: str
    psql: list[str]
    max_teams: int
    port_base: int
    port_stride: int
    postgres_port: int
    db_suffix_prefix: str


class Config(TypedDict):
    github: GitHubSettings
    team: TeamSettings
    timeouts: dict[str, int]
    launch: dict[str, str]
    agents: dict[str, AgentSpec]


class Allocation(TypedDict):
    """One launched client and its allocation, whose `id` never repeats. `pr` and `head` are
    set for reviewers of a pushed PR; `head` is the commit its bootstrap configuration names.

    `pane`, `name`, `kind`, `root` and `session` identify the client process. `launch` is
    new for each launch.
    `submission` is the task-submission state, separate from whether a process runs:
    NEVER_SUBMITTED until launch writes UNKNOWN, durably, before the client can accept any
    input; SUBMITTED only after the task prompt's positive transport result. SUBMITTED does
    not mean the task is done; the brief, PR and reviews record its outcome.
    """

    id: str
    entry: str
    role: str
    name: str
    kind: str
    root: str
    db_suffix: str
    port: int
    workspace: str
    tab: str
    pane: str
    session: str
    launch: str
    submission: str
    pr: NotRequired[str]
    head: NotRequired[str]


class Record(TypedDict):
    """A slot's record: its generation, the brief (or spec for a design team), the pair,
    its Herdr workspace and tabs, and every launched client. A slot number is reused; the
    generation is not. A design team has no pair."""

    version: int
    slot: int
    generation: int
    kind: str
    brief: str
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
# An allocation ID: the generation, then the entry. It never repeats.
ALLOCATION_ID = rf"g[0-9]+-{ENTRY}"
# Version 3 records live in the harness root and name projects, not worktrees.
RECORD_VERSION = 3
NEVER_SUBMITTED, UNKNOWN, SUBMITTED = "never_submitted", "unknown", "submitted"
AGENT_FIELDS = {
    "role",
    "kind",
    "model",
    "effort",
    "persona",
    "port_offset",
    "db_suffix",
}
# team.psql is a short argv list, never shell text.
ARGV_ARGS = 16
ARGV_ARG_CHARS = 256
# PostgreSQL truncates identifiers longer than this; partitions append up to three digits.
NAME_BYTES = 63
PARTITION_DIGITS = 3
DATABASE_BASES = ("tips_test", "tips_dev")
# Each GitHub read takes at most this many pages of 100 entries within this many seconds.
# Initial defaults, not measurements: widen them only after a legitimate read exceeds one.
READ_PAGES = 10
REPOSITORY = r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+"
TEMPORARY = ("/tmp", "/var/tmp")  # noqa: S108 - roots refused, never written
READ_SECONDS = 30
# Disable alternate language paths in launched clients, without editing user settings.
NATIVE_LSP_PLUGINS = {
    "elixir-lsp@elixir-agent-tools": False,
}


CommentType = Literal[
    "PROPOSAL",
    "CRITIQUE",
    "QUESTION",
    "ANSWER",
    "AGREE",
    "FINDING",
    "BLOCKED",
    "DONE",
    "EVENT",
]
COMMENT_TYPES: tuple[str, ...] = get_args(CommentType)
HEADER = re.compile(r"^(?P<type>[A-Z]+) (?P<role>\S+) (?P<name>\S+) (?P<session>\S+)$")


class DispatcherLaunch(TypedDict):
    """The launched dispatcher client: its process id and start time, pane and session.

    A restricted client reports no session to Herdr, so this record is its identity: the
    launcher execs the client, which keeps the launcher's process id.
    """

    pid: int
    started: str
    pane: str
    session: str


# Held by a running dispatcher and by a running team.py command; install.py checks both.
DISPATCHER_LOCK = "dispatcher.lock"
STORE_LOCK = ".lock"
# Written by the adapter when it first lists its tools: the client has them.
DISPATCHER_READY = "dispatcher.ready"
# Written by the dispatcher's starter when it could not send the first prompt.
DISPATCHER_RECOVERY = "dispatcher.recovery"


main: Path | None = None
cfg: Config | None = None


def configure() -> None:
    global main, cfg
    if os.environ.get("HERDR_ENV") != "1":
        raise RuntimeError("Run inside Herdr (HERDR_ENV=1)")
    main, cfg = load_config()


def settings() -> Config:
    if cfg is None:
        raise RuntimeError("Run configure() first")
    return cfg


def main_checkout() -> Path:
    if main is None:
        raise RuntimeError("Run configure() first")
    return main


def checkout_root(script: Path) -> Path:
    common = Path(
        run("git", "-C", script.parent, "rev-parse", "--path-format=absolute", "--git-common-dir")
    )
    return common.parent.resolve()


def config_location() -> tuple[Path, Path]:
    """The main checkout and the configuration file: TIPS_TEAM_CONFIG, else the default.
    Workers get the same file (agent_env)."""
    source = installed_source()
    if source is None:
        canonical = checkout_root(Path(__file__).resolve())
        default = canonical / "agent/teams/config.toml"
    else:
        # The installed harness reads its own reviewed configuration, by the stable link
        # its workers' scripts use (harness()).
        canonical = source
        default = cast(Path, installed("root")) / "harness/agent/teams/config.toml"
    return canonical, Path(os.environ.get("TIPS_TEAM_CONFIG", default))


def load_config() -> tuple[Path, Config]:
    canonical, path = config_location()
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
    for key in ("db_suffix_prefix", "clone_url"):
        require_type(settings.get(key), str, f"{path}: team.{key}")
    validate_github(path, fields.get("github"))
    validate_argv(f"{path}: team.psql", settings.get("psql"))
    if not Path(cast(list[str], settings["psql"])[0]).is_absolute():
        raise RuntimeError(f"{path}: team.psql must start with an absolute executable path")
    object_fields(fields.get("timeouts"), f"{path}: timeouts")
    policies = object_fields(fields.get("launch"), f"{path}: launch")
    for key in ("codex_approval", "claude_permission_mode"):
        require_type(policies.get(key), str, f"{path}: launch.{key}")
    agents = object_fields(fields.get("agents"), f"{path}: agents")
    if not agents:
        raise RuntimeError(f"{path}: agents must name at least one entry")
    for name, entry in agents.items():
        validate_agent_fields(f"{path}: agents.{name}", name, entry)


def validate_github(path: Path, value: object) -> None:
    github = object_fields(value, f"{path}: github")
    require_type(github.get("repository"), str, f"{path}: github.repository")
    if not re.fullmatch(REPOSITORY, str(github["repository"])):
        raise RuntimeError(f"{path}: github.repository must be owner/name")
    for number, names in object_fields(github.get("projects"), f"{path}: github.projects").items():
        if not number.isdecimal() or not isinstance(names, list):
            raise RuntimeError(f"{path}: github.projects maps a project number to field names")
        for name in cast(list[object], names):
            require_type(name, str, f"{path}: github.projects.{number}")


def validate_agent_fields(label: str, name: str, entry: object) -> None:
    if not re.fullmatch(ENTRY, name):
        raise RuntimeError(f"{label} must match {ENTRY}")
    spec = object_fields(entry, label)
    unknown = set(spec) - AGENT_FIELDS
    if unknown:
        raise RuntimeError(f"{label} has unknown keys {sorted(unknown)}")
    for key in ("role", "kind", "model", "effort", "db_suffix"):
        require_type(spec.get(key), str, f"{label}.{key}")
    if "persona" in spec:
        require_type(spec["persona"], str, f"{label}.persona")
    require_type(spec.get("port_offset"), int, f"{label}.port_offset")
    if not re.fullmatch(r"[^0-9]\S*", str(spec["db_suffix"])):
        raise RuntimeError(f"{label}.db_suffix must be nonempty and start with a non-digit")


def validate_argv(label: str, value: object) -> None:
    """1 to ARGV_ARGS nonempty strings; argv[0] names the program."""
    require_type(value, list, label)
    args = cast(list[object], value)
    if not 1 <= len(args) <= ARGV_ARGS:
        raise RuntimeError(f"{label} must hold 1 to {ARGV_ARGS} arguments")
    for arg in args:
        if not isinstance(arg, str) or not 0 < len(arg) <= ARGV_ARG_CHARS or "\0" in arg:
            raise RuntimeError(f"{label} arguments must be strings of 1 to {ARGV_ARG_CHARS} chars")


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


def allocation_id(generation: int, entry: str) -> str:
    return f"g{generation}-{entry}"


def launch_identity() -> tuple[str, Path]:
    """The calling client's allocation ID and the trusted state directory, from the
    environment its launch set; ValueError outside such a launch."""
    ident = os.environ.get("TIPS_TEAM_ALLOCATION_ID", "")
    state = os.environ.get("TIPS_TEAM_STATE", "")
    if not re.fullmatch(ALLOCATION_ID, ident) or not state:
        raise ValueError(
            "TIPS_TEAM_ALLOCATION_ID and TIPS_TEAM_STATE are not set; run this from the pane "
            "team.py launched"
        )
    if not Path(state).is_absolute() or Path(state).resolve() != Path(state):
        raise ValueError(f"TIPS_TEAM_STATE {state} is not a canonical absolute path")
    return ident, Path(state)


def slot_record_paths(state: Path) -> list[Path]:
    """The slot records, `<slot>.json`; other files there, such as dispatcher.json, are not."""
    return sorted(p for p in state.glob("*.json") if p.stem.isdecimal())


def unretired_allocations(state: Path) -> list[Path]:
    """The launcher configuration directories of allocations that stop has not retired."""
    return [
        path.parent
        for path in sorted(state.glob("*/bootstrap.json"))
        if not (path.parent / "retired.json").exists()
    ]


def allocation_port(team: TeamSettings, slot: int, offset: int) -> int:
    return team["port_base"] + slot * team["port_stride"] + offset


def is_partition(stem: str, name: str) -> bool:
    """Whether the database name is the stem or one of its numbered partitions."""
    return re.fullmatch(re.escape(stem) + r"[0-9]*", name) is not None


def overlapping(a: str, b: str) -> bool:
    """Whether one database stem is the other or one of its numbered partitions."""
    return is_partition(a, b) or is_partition(b, a)


def names_fit(stem: str) -> bool:
    """Whether every database name of the stem, partitions included, fits PostgreSQL."""
    return len((max(DATABASE_BASES, key=len) + stem).encode()) + PARTITION_DIGITS <= NAME_BYTES


def temporary_roots() -> list[Path]:
    """Temporary directories, which never hold the harness or its state."""
    return [Path(p).resolve() for p in (*TEMPORARY, os.environ.get("TMPDIR", "/tmp"))]  # noqa: S108 - refused roots


def within(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def database_stem(team: TeamSettings, slot: int, generation: int, suffix: str) -> str:
    """The slot, then the generation after a non-digit, then the entry's suffix, which starts
    with a non-digit: numbered partitions of one stem never equal another stem."""
    return f"{team['db_suffix_prefix']}{slot}g{generation}{suffix}"


def validate_allocations(path: Path, value: Config) -> None:
    """Ports and database stems of every slot are distinct, and a long generation still fits
    PostgreSQL's identifier length. Generations differ after the non-digit separator, so one
    generation's stems decide."""
    ports: set[int] = set()
    stems: list[str] = []
    team = value["team"]
    for n in range(1, team["max_teams"] + 1):
        for spec in value["agents"].values():
            port = allocation_port(team, n, spec["port_offset"])
            stem = database_stem(team, n, 1, spec["db_suffix"])
            if port in ports or not 1 <= port <= 65535:
                raise RuntimeError(f"{path}: overlapping or invalid test ports")
            if any(overlapping(stem, other) for other in stems):
                raise RuntimeError(f"{path}: overlapping database suffix/partition allocation")
            if not names_fit(database_stem(team, n, 10**6, spec["db_suffix"])):
                raise RuntimeError(f"{path}: database names would exceed {NAME_BYTES} bytes")
            ports.add(port)
            stems.append(stem)


def installed(key: str) -> Path | None:
    """A path install.json records for an operator-installed harness, or None in a checkout.
    install.py writes install.json beside the installed scripts."""
    record = Path(__file__).resolve().parent / "install.json"
    if not record.is_file():
        return None
    value = object_fields(json.loads(record.read_text()), str(record)).get(key)
    require_type(value, str, f"{record}: {key}")
    return Path(str(value))


def installed_source() -> Path | None:
    """The main checkout an installed harness names, or None in a checkout."""
    return installed("source")


def repo_key(repository: str) -> str:
    """The root's directory name: the repository name without its owner."""
    return repository.split("/")[-1]


def default_root(checkout: Path, repository: str) -> Path:
    """The harness and state root: agent_teams/<repository name>/ beside the checkout."""
    return checkout.resolve().parent / "agent_teams" / repo_key(repository)


def claim_root(root: Path, repository: str, checkout: Path) -> Path:
    """Create the root for this repository on first use, or refuse one that names another,
    including another owner's repository with the same name. The root must be a real path
    outside the checkout and outside temporary directories. It is not write-protected;
    repository.json only keeps two repositories apart."""
    if root.resolve() != root:
        raise RuntimeError(f"Harness root {root} passes through a symlink; refused")
    for parent in (checkout.resolve(), *temporary_roots()):
        if within(root, parent):
            raise RuntimeError(f"Harness root {root} is inside {parent}; refused")
    # Checked before the identity is published and before any record, lock or allocation
    # is written through them.
    directories = [contained(root / name, root) for name in ("state", "allocations")]
    identity = root / "repository.json"
    if not identity.exists():
        # Publish a complete identity with one exclusive link: of two first callers, the
        # second finds the first one's file and is refused below.
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=root, prefix=".repository.", delete=False) as f:
            f.write(json.dumps({"repository": repository}) + "\n")
        try:
            os.link(f.name, identity)
        except FileExistsError:
            pass
        finally:
            os.unlink(f.name)
    fields = object_fields(json.loads(identity.read_text()), str(identity))
    if fields.get("repository") != repository:
        raise RuntimeError(f"{root} belongs to {fields.get('repository')}, not {repository}")
    for directory in directories:
        directory.mkdir(exist_ok=True)
    return root


def harness_root() -> Path:
    """The parent of TIPS_TEAM_HARNESS, else the installed harness's recorded root, else
    the default beside the main checkout; created on first use. It must be a real path
    outside the repository and outside temporary directories."""
    override = os.environ.get("TIPS_TEAM_HARNESS")
    if override:
        if not Path(override).is_absolute():
            raise RuntimeError("TIPS_TEAM_HARNESS must be an absolute path")
        root = Path(override).parent
    else:
        root = installed("root") or default_root(
            main_checkout(), settings()["github"]["repository"]
        )
    return claim_root(root, settings()["github"]["repository"], main_checkout())


def state_dir() -> Path:
    return harness_root() / "state"


def contained(path: Path, parent: Path) -> Path:
    """Refuse a path that leaves its trusted parent or passes through a symlink."""
    if path.resolve() != path or parent not in path.parents:
        raise RuntimeError(f"{path} escapes {parent} or passes through a symlink; refused")
    return path


def allocation_paths(ident: str) -> tuple[Path, Path, Path, Path]:
    """The allocation's directory, its project and logs, and its launcher configuration.

    The allocation directory is the client's working root, so a Codex sandbox can write the
    clone's `.git`; the launcher configuration is outside it."""
    root = harness_root()
    base = root / "allocations" / ident
    return base, base / "project", base / "logs", root / "state" / ident


def project_of(allocation: Allocation) -> Path:
    return Path(allocation["root"]) / "project"


def live_name(slot: int, entry: str) -> str:
    return f"team-{slot}-{entry}"


def harness() -> Path:
    """The harness scripts workers call: <root>/harness/agent/teams for an installed
    harness, so commands keep working after the link moves to a new release; otherwise
    the running checkout's scripts."""
    if installed("root") is not None:
        return harness_root() / "harness/agent/teams"
    return Path(__file__).resolve().parent


def agent_spec(allocation: Allocation) -> AgentSpec:
    """The entry's current model settings; its kind and resources stay as recorded."""
    spec = settings()["agents"].get(allocation["entry"])
    if spec is None:
        raise RuntimeError(f"{allocation['entry']} was removed from config.toml; restore it first")
    if spec["kind"] != allocation["kind"]:
        raise RuntimeError(f"{allocation['entry']} was launched as {allocation['kind']}; preserved")
    return spec


def github_seconds() -> int:
    """The deadline of each GitHub operation: timeouts.github_seconds, else READ_SECONDS.
    Before configure(), as repository() does, it reads the configuration file."""
    timeouts = (cfg or load_config()[1])["timeouts"]
    return timeouts.get("github_seconds", READ_SECONDS)


def repository() -> str:
    """The configured owner/name; never discovered from a working directory. Before
    configure(), such as under `pr_review.py list`, it reads the configuration file."""
    if cfg is None:
        return load_config()[1]["github"]["repository"]
    return cfg["github"]["repository"]
