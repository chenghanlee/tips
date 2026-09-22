#!/usr/bin/env python3
"""Local Herdr team lifecycle; shared stop_agent is safe to import."""

import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import uuid
from collections.abc import Sequence
from pathlib import Path
from typing import NotRequired, TypedDict, cast


class Role(TypedDict):
    """Role settings; resource fields are used only by coding roles."""

    kind: str
    model: str
    effort: str
    compaction_percent: NotRequired[int]


class CodingRole(Role):
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


class ProcessInfo(TypedDict):
    shell_pid: int
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
) -> subprocess.CompletedProcess[str]:
    """Run a resolved executable without a shell and capture its output."""
    return subprocess.run(
        command_args(args, path=env.get("PATH", os.defpath) if env is not None else None, cwd=cwd),
        cwd=cwd,
        env=env,
        timeout=timeout,
        check=check,
        text=True,
        capture_output=True,
    )


def run(
    *args: str | Path | int, cwd: str | Path | None = None, timeout: float | None = None
) -> str:
    p = execute(args, cwd=cwd, timeout=timeout)
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"Command failed: {args}")
    return p.stdout.strip()


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
    for process in object_list(info.get("foreground_processes"), "Herdr foreground_processes"):
        require_type(process.get("pid"), int, "Herdr process pid")
        if "cwd" in process:
            require_type(process["cwd"], str, "Herdr process cwd")


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
        raise RuntimeError(f"{pane}: cannot stop the calling agent; ask its TPM to stop it")
    identity = {pid: rows[pid][1] for pid in owned if pid in rows}
    signal_client(pane, current, clients, owned)
    wait_for_exit(pane, shell, identity)
    release_name(pane, root, current)
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


def release_name(pane: str, root: Path, current: Entity) -> None:
    # Process exit can precede Herdr's name release; retire only this stopped owner.
    for agent in herdr("agent", "list")["agents"]:
        if agent.get("pane_id") == pane and agent.get("name"):
            if (
                agent.get("agent") != current.get("agent")
                or Path(agent.get("foreground_cwd") or agent.get("cwd", "")).resolve() != root
            ):
                raise RuntimeError(f"{pane}: owner changed during shutdown; preserved")
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
    canonical = common.parent
    path = Path(os.environ.get("TIPS_TEAM_CONFIG", canonical / "agent/teams/config.toml"))
    with path.open("rb") as f:
        value = cast(Config, tomllib.load(f))
    validate_config_fields(path, value)
    validate_settings(path, value)
    validate_allocations(path, value)
    validate_compaction(path, value)
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
    for key in ("codex_approval", "codex_lsp_approval_mode", "claude_permission_mode"):
        require_type(policies.get(key), str, f"{path}: launch.{key}")
    roles = object_fields(fields.get("roles"), f"{path}: roles")
    for name in ("dev", "test", "lead", "tpm", "lead_tpm"):
        validate_role_fields(roles.get(name), f"{path}: roles.{name}", name)


def validate_role_fields(value: object, label: str, name: str) -> None:
    role = object_fields(value, label)
    for key in ("kind", "model", "effort"):
        require_type(role.get(key), str, f"{label}.{key}")
    if name in ("dev", "test", "lead"):
        require_type(role.get("port_offset"), int, f"{label}.port_offset")
        require_type(role.get("db_suffix"), str, f"{label}.db_suffix")
    if name in ("tpm", "lead_tpm") or "compaction_percent" in role:
        require_type(role.get("compaction_percent"), int, f"{label}.compaction_percent")


def validate_settings(path: Path, value: Config) -> None:
    for key in (
        "launch_seconds",
        "shutdown_seconds",
        "shell_seconds",
        "checks_minutes",
        "mcp_startup_seconds",
        "mcp_tool_seconds",
    ):
        if type(value["timeouts"][key]) is not int or value["timeouts"][key] <= 0:
            raise RuntimeError(f"{path}: timeouts.{key} must be a positive integer")
    if value["team"]["max_teams"] < 1:
        raise RuntimeError(f"{path}: team.max_teams must be positive")
    for name in ("dev", "test", "lead", "tpm", "lead_tpm"):
        role = value["roles"][name]
        if role["kind"] not in ("codex", "claude"):
            raise RuntimeError(f"{path}: invalid role {name}")
    if value["launch"]["codex_lsp_approval_mode"] not in ("auto", "prompt", "writes", "approve"):
        raise RuntimeError(f"{path}: invalid Codex LSP approval mode")


def validate_allocations(path: Path, value: Config) -> None:
    ports: set[int] = set()
    stems: list[str] = []
    for n in range(1, value["team"]["max_teams"] + 1):
        for role in ("dev", "test", "lead"):
            spec = cast(CodingRole, value["roles"][role])
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


def validate_compaction(path: Path, value: Config) -> None:
    for role in ("tpm", "lead_tpm"):
        percent = value["roles"][role].get("compaction_percent")
        if type(percent) is not int or not 1 <= percent <= 100:
            raise RuntimeError(f"{path}: invalid coordinator compaction percentage")


def matching_workspace(label: str) -> Entity | None:
    matches = [w for w in herdr("workspace", "list")["workspaces"] if w.get("label") == label]
    if len(matches) > 1:
        raise RuntimeError(f"Ambiguous workspace label: {label}")
    return matches[0] if matches else None


def pane_roles(workspace: Entity, names: list[str]) -> dict[str, Entity]:
    result: dict[str, Entity] = {}
    for pane in herdr("pane", "list", "--workspace", workspace["workspace_id"])["panes"]:
        label = pane.get("label")
        if label not in names or label in result:
            raise RuntimeError(f"Unexpected or duplicate pane {pane['pane_id']}; preserved")
        result[label] = pane
    return result


def coordinator(pane: Entity, name: str, role: str) -> None:
    spec = cfg["roles"][role]
    if pane.get("agent"):
        agent = herdr("agent", "get", pane["pane_id"])["agent"]
        if (
            agent.get("name") != name
            or agent.get("agent") != spec["kind"]
            or Path(agent.get("foreground_cwd", "")).resolve() != main
        ):
            raise RuntimeError(f"{pane['pane_id']}: conflicting coordinator; preserved")
        if agent.get("agent_status") in ("blocked", "unknown"):
            raise RuntimeError(f"{pane['pane_id']}: coordinator is not ready; inspect its pane")
        return
    info = herdr("pane", "process-info", "--pane", pane["pane_id"])["process_info"]
    if any(p["pid"] != info["shell_pid"] for p in info["foreground_processes"]):
        raise RuntimeError(f"{pane['pane_id']}: not an available shell")
    token = "team-setup-" + uuid.uuid4().hex
    env = {
        "TIPS_CHECK_TIMEOUT_SECONDS": str(cfg["timeouts"]["checks_minutes"] * 60),
        "TIPS_TEAM_CONFIG": str(
            Path(os.environ.get("TIPS_TEAM_CONFIG", main / "agent/teams/config.toml")).resolve()
        ),
    }
    if spec["kind"] == "claude":
        env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = str(spec.get("compaction_percent"))
    command = (
        "cd -- "
        + shlex.quote(str(main))
        + " && unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE && export "
        + shlex.join([f"{k}={v}" for k, v in env.items()])
    )
    # Split the marker so terminal input echo cannot satisfy the output acknowledgment.
    command += " && printf '%s%s\\n' " + shlex.join([token[:10], token[10:]])
    herdr("pane", "run", pane["pane_id"], command)
    herdr(
        "pane",
        "wait-output",
        pane["pane_id"],
        "--match",
        token,
        "--source",
        "detection",
        "--timeout",
        str(cfg["timeouts"]["shell_seconds"] * 1000),
    )
    if spec["kind"] == "claude":
        args = [
            "--permission-mode",
            cfg["launch"]["claude_permission_mode"],
            "--effort",
            spec["effort"],
            "--settings",
            json.dumps({"enabledPlugins": {"elixir-lsp@elixir-agent-tools": False}}),
            "--strict-mcp-config",
            "--mcp-config",
            '{"mcpServers":{}}',
        ]
        if spec["model"]:
            args += ["--model", spec["model"]]
    else:
        args = [
            "-a",
            cfg["launch"]["codex_approval"],
            "-C",
            str(main),
            "-c",
            "mcp_servers.elixir-lsp.enabled=false",
            "-c",
            "model_reasoning_effort=" + json.dumps(spec["effort"]),
        ]
        if spec["model"]:
            args += ["-m", spec["model"]]
    herdr(
        "agent",
        "start",
        name,
        "--kind",
        spec["kind"],
        "--pane",
        pane["pane_id"],
        "--timeout",
        str(cfg["timeouts"]["launch_seconds"] * 1000),
        "--",
        *args,
    )
    started = herdr("agent", "get", pane["pane_id"])["agent"]
    if (
        started.get("name") != name
        or started.get("agent") != spec["kind"]
        or Path(started.get("foreground_cwd", "")).resolve() != main
        or started.get("agent_status") in ("blocked", "unknown")
    ):
        raise RuntimeError(
            "Coordinator launch returned an unexpected client/root/state; inspect its pane"
        )
    herdr(
        "agent",
        "prompt",
        name,
        (
            "Read agent/teams/README.md. You are "
            f"{name}"
            ". Coordinate from this read-only main checkout; coding agents sta"
            "rt only in assigned worktrees. Use agent/teams/config.toml for la"
            "unch settings. Only the team TPM advances review stages. Each dis"
            "patch must include the exact herdr agent prompt command addressed"
            " to its TPM, to execute after posting evidence and before ending "
            "the turn, including on a blocker. A GitHub comment or final chat "
            "response is not a delivered handoff. Use short messages with evid"
            "ence link, SHA, action and owner. Run commands directly; no hooks"
            ", --wait, polling, output pipelines or ad hoc JSON formatters. Re"
            "port readiness to "
            f"{('the user' if role == 'lead_tpm' else 'lead-tpm')}"
            "; await assignment."
        ),
    )


def start(target: str) -> None:
    is_lead = target == "lead"
    names = (
        ["lead-tpm"]
        if is_lead
        else [f"team-{target}-{role}" for role in ("tpm", "dev", "test", "lead")]
    )
    label = cfg["team"]["workspace_prefix"] + "-" + target
    workspace = matching_workspace(label)
    if workspace:
        panes = pane_roles(workspace, names)
    else:
        created = herdr("workspace", "create", "--cwd", str(main), "--label", label, "--no-focus")
        workspace = created["workspace"]
        first = created["root_pane"]
        herdr("pane", "rename", first["pane_id"], names[0])
        first["label"] = names[0]
        panes = {names[0]: first}
    for index, name in enumerate(names):
        if name not in panes:
            anchor = panes[names[0 if index < 3 else 1]]
            pane = herdr(
                "pane",
                "split",
                anchor["pane_id"],
                "--direction",
                "right" if index == 1 else "down",
                "--cwd",
                str(main),
                "--no-focus",
            )["pane"]
            herdr("pane", "rename", pane["pane_id"], name)
            panes[name] = pane
    coordinator(panes[names[0]], names[0], "lead_tpm" if is_lead else "tpm")
    for name, pane in panes.items():
        print(f"{name}: {pane['pane_id']}")
    print(
        "Coordinator launched; coding panes await assignment."
        if not is_lead
        else "Lead TPM launched."
    )


def git(*args: str | Path, root: Path | None = None) -> str:
    return run("git", "-C", root or main, *args)


def stop_team(target: str) -> None:
    label = cfg["team"]["workspace_prefix"] + "-" + target
    workspace = matching_workspace(label)
    if not workspace:
        print(f"{label}: no workspace; nothing removed")
        return
    roles = ("tpm", "dev", "test", "lead")
    names = [f"team-{target}-{r}" for r in roles]
    panes = pane_roles(workspace, names)
    roots = owned_worktrees(panes)
    if roots:
        git("fetch", "origin")
    check_worktrees(roots)
    for pane in panes.values():
        stop(pane["pane_id"], pane.get("foreground_cwd", pane["cwd"]))
    check_worktrees(roots)
    if roots or panes:
        drop_databases(target)
    for root in sorted(roots):
        git("worktree", "remove", root)
    herdr("workspace", "close", workspace["workspace_id"])
    print(f"{label}: closed; main checkout status follows")
    print(git("status", "--short") or "Main checkout clean")


def owned_worktrees(panes: dict[str, Entity]) -> set[Path]:
    roots: set[Path] = set()
    # Validate every pane before stopping any client.
    for name, pane in panes.items():
        root = Path(pane.get("foreground_cwd", pane["cwd"])).resolve()
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


def drop_databases(target: str) -> None:
    prefix = cfg["team"]["db_suffix_prefix"] + target
    stems = [
        "tips_test" + prefix + cast(CodingRole, cfg["roles"][r])["db_suffix"]
        for r in ("dev", "test", "lead")
    ]
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
    if len(args) != 2 or args[0] not in ("start", "stop"):
        raise RuntimeError("Usage: agent/teams/team.py start|stop N; start lead")
    target = args[1]
    if target == "lead":
        if args[0] != "start":
            raise RuntimeError("Only start lead is supported; exit that client normally")
    elif (
        not target.isdecimal()
        or not 1 <= int(target) <= cfg["team"]["max_teams"]
        or str(int(target)) != target
    ):
        raise RuntimeError("Team must be within config team.max_teams")
    (start if args[0] == "start" else stop_team)(target)


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
