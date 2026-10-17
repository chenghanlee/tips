"""Start the dispatcher in this Herdr pane, or in a new sibling pane with --new-pane.

The dispatcher is Claude in restricted mode with no built-in tools and one MCP server,
adapter.py, under strict MCP configuration. Its trusted role and workflow text is the
system prompt, read here before start: the dispatcher cannot read files or run commands.
The launcher assigns the session ID. Once the adapter has listed its tools to this session
(state/dispatcher.ready) and Herdr shows the launched client ready for input, it names the
pane `dispatcher` and sends the first prompt, `Begin.`, through Herdr.
Settings are [dispatcher] in config.toml.
"""

import contextlib
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

import commands
import config as conf
import herdr
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
    # No command-line prompt: a first turn started with the process could run before the
    # adapter's tools connect. The starter sends it once the adapter has listed them.
    return [*args, "--system-prompt", system_prompt()]


def note(state: Path, name: str, session: str) -> bool:
    """Whether state/<name> was written for this session."""
    try:
        fields = commands.object_fields(json.loads((state / name).read_text()), name)
    except (OSError, ValueError, RuntimeError):
        return False
    return fields.get("session") == session


def call(args: list[str], seconds: float) -> str | None:
    """Run one Herdr command; None on success, else the failure with its cause."""
    try:
        result = commands.execute(args, timeout=seconds)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        return f"{' '.join(args[:3])}: {error}"
    if result.returncode:
        cause = (result.stderr or result.stdout).strip() or f"exit {result.returncode}"
        return f"{' '.join(args[:3])}: {cause}"
    return None


def ready_client(state: Path, launch: conf.DispatcherLaunch, seconds: float) -> bool:
    """Whether the adapter has listed its tools to this session and Herdr sees the recorded
    launched process in the pane, ready for input. A failed read counts as not ready."""
    if not note(state, conf.DISPATCHER_READY, launch["session"]):
        return False
    pane = launch["pane"]
    try:
        info = commands.execute(["herdr", "pane", "process-info", "--pane", pane], timeout=seconds)
        agent = commands.execute(["herdr", "agent", "get", pane], timeout=seconds)
        if info.returncode or agent.returncode:
            return False
        leader = herdr.parse_herdr(info.stdout)["process_info"]["foreground_process_group_id"]
        fields = herdr.parse_herdr(agent.stdout)["agent"]
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired):
        return False
    return (
        fields.get("agent") == "claude"
        and fields.get("agent_status") in ("idle", "done")
        and leader == launch["pid"]
        and team.dispatcher_running(launch)
    )


def start_when_ready(state: Path, launch: conf.DispatcherLaunch, seconds: float) -> int:
    """Once the client has the tools and is ready for input, name it `dispatcher` and send
    `Begin.`, the same Herdr prompt path team.py uses for workers. Otherwise tell the
    operator what happened and what to run, in a Herdr notification and in
    state/dispatcher.recovery, which `team.py status` shows. A failed prompt may still have
    been delivered, so its note asks the operator to check the pane before sending again."""
    pane = launch["pane"]
    prompt = f'herdr agent prompt {pane} "Begin."'
    both = f"herdr agent rename {pane} dispatcher && {prompt}"
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if ready_client(state, launch, seconds):
            failed = call(["herdr", "agent", "rename", pane, "dispatcher"], seconds)
            if failed:
                return give_up(
                    state,
                    launch,
                    seconds,
                    f"naming it failed ({failed}); Begin. was not sent. "
                    f"Check the pane, then run: {both}",
                )
            failed = call(["herdr", "agent", "prompt", pane, "Begin."], seconds)
            if failed is None:
                return 0
            return give_up(
                state,
                launch,
                seconds,
                f"Begin. may or may not have reached it ({failed}). "
                f"Check the pane; only if it shows no Begin. turn, run: {prompt}",
            )
        time.sleep(0.5)
    return give_up(
        state,
        launch,
        seconds,
        f"it was not ready within {seconds:g} s; Begin. was not sent. "
        f"Check the pane, then run: {both}",
    )


def give_up(state: Path, launch: conf.DispatcherLaunch, seconds: float, what: str) -> int:
    message = f"Dispatcher in {launch['pane']}: {what}"
    with contextlib.suppress(OSError):
        recovery = state / conf.DISPATCHER_RECOVERY
        recovery.write_text(json.dumps({"session": launch["session"], "text": message}) + "\n")
    show = ["herdr", "notification", "show", "Dispatcher not started", "--body", message]
    call(show, seconds)
    return 1


def hold_start_lock() -> int:
    """Lock <root>/state/dispatcher.lock for the life of the client; refuse if it is held.

    Deliberately the opposite of team.py's store lock, which is close-on-exec and ends with
    the command: this descriptor is inheritable, so exec hands it to the client. A second
    launcher then fails at once while the client, or any process it started that kept the
    descriptor, runs. That serializes check, record and exec, and the kernel releases it
    when they exit, so a crash leaves nothing to clean up.
    """
    path = conf.harness_root() / "state" / conf.DISPATCHER_LOCK
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
    listed = herdr.parse_herdr(commands.run("herdr", "agent", "list", timeout=launch_seconds))
    named = [a["pane_id"] for a in listed["agents"] if a.get("name") == "dispatcher"]
    if named:
        raise RuntimeError(
            f"{named[0]} is named dispatcher but is not the recorded launch; cannot confirm "
            "which client it is; preserved. Exit or rename it, then start the dispatcher."
        )
    session = str(uuid.uuid4())
    args = client_args(settings, session, config)
    state = team.dispatcher_path().parent
    for name in (conf.DISPATCHER_READY, conf.DISPATCHER_RECOVERY):
        (state / name).unlink(missing_ok=True)
    # This process becomes the client through exec, so its id and start time identify it.
    launch = team.record_dispatcher(pane, session)
    # The starter outlives this process; it stops at its deadline.
    # Reviewed S603: fixed argv of this script, no shell.
    starter = [sys.executable, "-E", "-s", str(Path(__file__).resolve()), "--start"]
    subprocess.Popen(  # noqa: S603
        [*starter, str(state), json.dumps(launch), str(launch_seconds)],
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.chdir(main)
    env = dict(os.environ, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=str(settings["compact_percent"]))
    print(f"Dispatcher session {session}", flush=True)
    os.execvpe(commands.command_args(args)[0], args, env)  # noqa: S606


def pane_width(layout: str, pane: str) -> int:
    result = commands.object_fields(json.loads(layout), "Herdr layout").get("result")
    panes = commands.object_fields(commands.object_fields(result, "result").get("layout"), "layout")
    for entry in commands.object_list(panes.get("panes"), "panes"):
        if entry.get("pane_id") == pane:
            width = commands.object_fields(entry.get("rect"), "rect").get("width")
            commands.require_type(width, int, "pane width")
            return int(str(width))
    raise RuntimeError(f"Herdr layout has no pane {pane}")


def start_in_new_pane(main: Path, config: Path, launch_seconds: int) -> None:
    if not os.environ.get("HERDR_PANE_ID"):
        raise RuntimeError("--new-pane requires a session running inside Herdr.")
    layout = commands.run("herdr", "pane", "layout", "--current", timeout=launch_seconds)
    direction = "right" if pane_width(layout, os.environ["HERDR_PANE_ID"]) >= 120 else "down"
    split = ["pane", "split", "--current", "--direction", direction, "--cwd", str(main)]
    created = commands.run("herdr", *split, "--no-focus", timeout=launch_seconds)
    pane = herdr.parse_herdr(created)["pane"]["pane_id"]
    command = f"TIPS_TEAM_CONFIG={shlex.quote(str(config))} {shlex.quote(str(HERE / 'dispatch'))}"
    commands.run("herdr", "pane", "run", pane, command, timeout=launch_seconds)
    print(
        f"Dispatcher launch submitted to Herdr pane {pane}. "
        "Check that pane for startup or approval prompts."
    )


def main(argv: list[str]) -> None:
    if argv[:1] == ["--start"] and len(argv) == 4:
        launch = cast(conf.DispatcherLaunch, commands.object_fields(json.loads(argv[2]), "launch"))
        sys.exit(start_when_ready(Path(argv[1]), launch, float(argv[3])))
    if argv not in ([], ["--new-pane"]):
        raise SystemExit("Usage: agent/teams/dispatch [--new-pane]")
    if os.environ.get("HERDR_ENV") != "1":
        raise RuntimeError("Run inside Herdr (HERDR_ENV=1)")
    main_checkout, config = conf.config_location()
    conf.configure()
    with config.open("rb") as file:
        settings = tomllib.load(file)["dispatcher"]
    launch_seconds = conf.settings()["timeouts"]["launch_seconds"]
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
