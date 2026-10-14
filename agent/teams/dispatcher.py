"""Start the dispatcher in this Herdr pane, or in a new sibling pane with --new-pane.

The dispatcher is Claude in restricted mode with no built-in tools and one MCP server,
adapter.py, under strict MCP configuration. Its trusted role and workflow text is the
system prompt, read here before start: the dispatcher cannot read files or run commands.
The launcher assigns the session ID and names the pane `dispatcher` in Herdr itself.
Settings are [dispatcher] in config.toml.
"""

import fcntl
import json
import os
import shlex
import subprocess
import sys
import time
import tomllib
import uuid
from pathlib import Path
from typing import cast

import team

HERE = Path(__file__).resolve().parent
# The reviewed tree holding AGENTS.md: the checkout, or the installed harness.
DOCUMENTS = HERE.parents[1]
PROMPT_FILES = (
    "AGENTS.md",
    "agent/teams/README.md",
    "agent/teams/roles/common.md",
    "agent/teams/roles/dispatcher.md",
)
# The launcher owns every setting the client loads. Restricted mode ignores user, project
# and local settings and CLAUDE.md; this turns off Remote Control, another input source.
SETTINGS = {"remoteControlAtStartup": False}
PREAMBLE = """You are the Tips dispatcher. Herdr names you `dispatcher`; agents message you.
You have no shell, file, web or code tools. Act only through the `tips` tools: each is one
fixed harness or GitHub operation. Where the files below say to run a command, use the
tool for that operation; if no tool covers it, report it to the user and do not ask
another agent to run it for you. The files below are your trusted instructions. They stay
in this system prompt, so you never need to reread them.
"""


def system_prompt() -> str:
    parts = [PREAMBLE]
    for name in PROMPT_FILES:
        text = (DOCUMENTS / name).read_text()
        parts.append(f"\n<file path={json.dumps(name)}>\n{text}</file>\n")
    return "".join(parts)


def adapter_python() -> Path:
    python = HERE / ".venv/bin/python"
    if not os.access(python, os.X_OK):
        raise RuntimeError(
            f"Missing {python}: install the harness (install.py) or create the locked "
            "environment (agent/teams/development.md)."
        )
    return python


def mcp_config(session: str, config: Path) -> str:
    """Strict configuration naming one server: the adapter, with its identity and config."""
    server = {
        "type": "stdio",
        "command": str(adapter_python()),
        "args": ["-E", "-s", str(HERE / "adapter.py")],
        "env": {"TIPS_DISPATCHER_SESSION": session, "TIPS_TEAM_CONFIG": str(config)},
    }
    return json.dumps({"mcpServers": {"tips": server}})


def client_args(settings: dict[str, object], session: str, config: Path) -> list[str]:
    model, effort = str(settings["model"]), str(settings["effort"])
    args = [
        "claude",
        "--restricted",
        "--tools",
        "",
        "--strict-mcp-config",
        "--mcp-config",
        mcp_config(session, config),
        "--settings",
        json.dumps(SETTINGS),
        "--allowedTools",
        "mcp__tips",
        "--session-id",
        session,
        "--effort",
        effort,
    ]
    if model:
        args += ["--model", model]
        if "fable" not in model:
            args += ["--advisor", "fable"]
    return [*args, "--system-prompt", system_prompt(), "Begin."]


def launched_client(pane: str, launch: team.DispatcherLaunch, seconds: float) -> bool:
    """Whether Herdr sees a client in the pane and it is the recorded launched process."""
    info = team.execute(["herdr", "pane", "process-info", "--pane", pane], timeout=seconds)
    agent = team.execute(["herdr", "agent", "get", pane], timeout=seconds)
    if info.returncode or agent.returncode:
        return False
    leader = team.parse_herdr(info.stdout)["process_info"]["foreground_process_group_id"]
    kind = team.parse_herdr(agent.stdout)["agent"].get("agent")
    return kind == "claude" and leader == launch["pid"] and team.dispatcher_running(launch)


def name_when_ready(launch: team.DispatcherLaunch, seconds: float) -> None:
    """Name the pane's client `dispatcher` once Herdr detects it as the launched process."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if launched_client(launch["pane"], launch, seconds):
            rename = ["herdr", "agent", "rename", launch["pane"], "dispatcher"]
            team.execute(rename, timeout=seconds)
            return
        time.sleep(0.5)


def hold_start_lock() -> int:
    """Lock <root>/state/dispatcher.lock for the life of the client; refuse if it is held.

    Deliberately the opposite of team.py's store lock, which is close-on-exec and ends with
    the command: this descriptor is inheritable, so exec hands it to the client. A second
    launcher then fails at once while the client, or any process it started that kept the
    descriptor, runs. That serializes check, record and exec, and the kernel releases it
    when they exit, so a crash leaves nothing to clean up.
    """
    path = team.harness_root() / "state/dispatcher.lock"
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise RuntimeError(
            f"Busy: a dispatcher is running or starting ({path} is locked); start one only."
        ) from None
    os.set_inheritable(descriptor, True)
    return descriptor


def start_here(settings: dict[str, object], main: Path, config: Path, launch_seconds: int) -> None:
    pane = os.environ.get("HERDR_PANE_ID", "")
    if not pane:
        raise RuntimeError("HERDR_PANE_ID is not set; start the dispatcher inside Herdr.")
    hold_start_lock()
    # Uncertain identity blocks: refuse unless no dispatcher can be running.
    launch = team.dispatcher_launch()
    if launch and team.dispatcher_running(launch):
        raise RuntimeError(
            f"The dispatcher is already running as pid {launch['pid']} in {launch['pane']}; "
            "start one only."
        )
    listed = team.parse_herdr(team.run("herdr", "agent", "list", timeout=launch_seconds))
    named = [a["pane_id"] for a in listed["agents"] if a.get("name") == "dispatcher"]
    if named:
        raise RuntimeError(
            f"{named[0]} is named dispatcher but is not the recorded launch; cannot confirm "
            "which client it is; preserved. Exit or rename it, then start the dispatcher."
        )
    session = str(uuid.uuid4())
    args = client_args(settings, session, config)
    # This process becomes the client through exec, so its id and start time identify it.
    launch = team.record_dispatcher(pane, session)
    # The namer outlives this process; it stops at its deadline.
    # Reviewed S603: fixed argv of this script, no shell.
    namer = [sys.executable, "-E", "-s", str(Path(__file__).resolve()), "--name"]
    subprocess.Popen(  # noqa: S603
        [*namer, json.dumps(launch), str(launch_seconds)],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.chdir(main)
    env = dict(os.environ, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=str(settings["compact_percent"]))
    print(f"Dispatcher session {session}", flush=True)
    os.execvpe(team.command_args(args)[0], args, env)  # noqa: S606


def pane_width(layout: str, pane: str) -> int:
    result = team.object_fields(json.loads(layout), "Herdr layout").get("result")
    panes = team.object_fields(team.object_fields(result, "result").get("layout"), "layout")
    for entry in team.object_list(panes.get("panes"), "panes"):
        if entry.get("pane_id") == pane:
            width = team.object_fields(entry.get("rect"), "rect").get("width")
            team.require_type(width, int, "pane width")
            return int(str(width))
    raise RuntimeError(f"Herdr layout has no pane {pane}")


def start_in_new_pane(main: Path, config: Path, launch_seconds: int) -> None:
    if not os.environ.get("HERDR_PANE_ID"):
        raise RuntimeError("--new-pane requires a session running inside Herdr.")
    layout = team.run("herdr", "pane", "layout", "--current", timeout=launch_seconds)
    direction = "right" if pane_width(layout, os.environ["HERDR_PANE_ID"]) >= 120 else "down"
    split = ["pane", "split", "--current", "--direction", direction, "--cwd", str(main)]
    created = team.run("herdr", *split, "--no-focus", timeout=launch_seconds)
    pane = team.parse_herdr(created)["pane"]["pane_id"]
    command = f"TIPS_TEAM_CONFIG={shlex.quote(str(config))} {shlex.quote(str(HERE / 'dispatch'))}"
    team.run("herdr", "pane", "run", pane, command, timeout=launch_seconds)
    print(
        f"Dispatcher launch submitted to Herdr pane {pane}. "
        "Check that pane for startup or approval prompts."
    )


def main(argv: list[str]) -> None:
    if argv[:1] == ["--name"] and len(argv) == 3:
        launch = team.object_fields(json.loads(argv[1]), "launch")
        name_when_ready(cast(team.DispatcherLaunch, launch), float(argv[2]))
        return
    if argv not in ([], ["--new-pane"]):
        raise SystemExit("Usage: agent/teams/dispatch [--new-pane]")
    if os.environ.get("HERDR_ENV") != "1":
        raise RuntimeError("Run inside Herdr (HERDR_ENV=1)")
    main_checkout, config = team.config_location()
    team.main, team.cfg = team.load_config()
    if not team.github_settings():
        raise RuntimeError(f"{config} has no [github] table; the adapter needs it")
    with config.open("rb") as file:
        settings = tomllib.load(file)["dispatcher"]
    launch_seconds = team.cfg["timeouts"]["launch_seconds"]
    if argv == ["--new-pane"]:
        start_in_new_pane(main_checkout, config, launch_seconds)
    else:
        start_here(settings, main_checkout, config, launch_seconds)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"dispatch: {error}", file=sys.stderr)
        sys.exit(1)
