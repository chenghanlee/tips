#!/usr/bin/env python3
"""Internal worktree provisioning and client launch for the team lifecycle."""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Sequence
from pathlib import Path
from typing import cast

from team import (
    CodingRole,
    Config,
    Entity,
    HerdrResult,
    execute,
    load_config,
    parse_herdr,
    stop_agent,
)


class RefusalError(Exception):
    pass


def run(
    argv: Sequence[str | Path], *, timeout: float | None = None, env: dict[str, str] | None = None
) -> str:
    result = execute(argv, timeout=timeout, env=env)
    if result.returncode:
        raise RefusalError(
            f"{shlex.join(map(str, argv))} failed: {result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout.strip()


def git(*args: str | Path) -> str:
    return run(["git", *map(str, args)])


class Arguments(argparse.Namespace):
    task: str
    team: int
    pane: str
    agent: str | None
    role: str | None
    kind: str | None
    review_ref: str | None
    start: bool
    force: bool
    ui: bool


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(
        description=(
            "Provision one task/reviewer worktree; --start launches its configured client in Herdr."
        )
    )
    parser.add_argument("task")
    parser.add_argument("--team", required=True, type=int)
    parser.add_argument("--pane", required=True)
    parser.add_argument("--agent")
    parser.add_argument("--role", choices=["dev", "lead", "test"])
    parser.add_argument(
        "--kind", choices=["codex", "claude"], help="Must match the configured role kind"
    )
    parser.add_argument("--review-ref")
    parser.add_argument(
        "--ui",
        action="store_true",
        help="Launch the lead with roles.lead_ui (issues labelled ui); lead role only",
    )
    parser.add_argument("--start", action="store_true")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace differing selected-client configuration while no client is running",
    )
    return parser.parse_args(namespace=Arguments())


def validate_arguments(args: Arguments) -> tuple[str, str]:
    if not re.fullmatch(r"[0-9]+-[a-z0-9]+(?:-[a-z0-9]+)*", args.task):
        raise RefusalError("Task must be <issue>-<slug>.")
    if not re.fullmatch(r"w[A-Za-z0-9]+:p[A-Za-z0-9]+", args.pane):
        raise RefusalError("Invalid Herdr pane ID.")
    inferred = re.fullmatch(r"team-([0-9]+)-(dev|lead|test)", args.agent or "")
    role_name = args.role or (inferred.group(2) if inferred else "dev")
    if inferred and (int(inferred.group(1)) != args.team or inferred.group(2) != role_name):
        raise RefusalError("Agent name must match its requested team and role.")
    agent_name = args.agent or f"team-{args.team}-{role_name}"
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", agent_name):
        raise RefusalError("Invalid Herdr agent name.")

    return role_name, agent_name


class WorktreeTask:
    args: Arguments
    root: Path
    config_path: Path
    config: Config
    role: CodingRole
    role_name: str
    agent_name: str
    issue: str
    worktree: Path
    branch: str
    existing_branch: bool
    wrapper: Path
    review_sha: str | None
    old_head: str | None
    desired: dict[Path, str]
    changed: list[Path]
    owner: Entity | None

    def __init__(self, args: Arguments) -> None:
        self.args = args
        self.role_name, self.agent_name = validate_arguments(self.args)
        self.root = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent
        if Path.cwd() != self.root:
            raise RefusalError(f"Run from the main checkout: {self.root}")
        self.config_path = Path(
            os.environ.get("TIPS_TEAM_CONFIG", str(self.root / "agent/teams/config.toml"))
        ).resolve()
        _, self.config = load_config()
        self.team, self.timeouts, self.policies = (
            self.config["team"],
            self.config["timeouts"],
            self.config["launch"],
        )
        self.role = cast(CodingRole, self.config["roles"][self.role_key()])
        self.kind = self.role["kind"]
        self.check_settings()
        self.model, self.effort = (self.role["model"], self.role["effort"])
        self.port = (
            self.team["port_base"]
            + self.team["port_stride"] * self.args.team
            + self.role["port_offset"]
        )
        if not 1 <= self.port <= 65535:
            raise RefusalError("Configured role port is outside the TCP port range.")
        self.target_env = {
            "PGPORT": str(self.team["postgres_port"]),
            "TIPS_DB_SUFFIX": self.team["db_suffix_prefix"]
            + str(self.args.team)
            + self.role["db_suffix"],
            "TIPS_TEST_PORT": str(self.port),
            "MIX_ENV": "test",
            "TIPS_CHECK_TIMEOUT_SECONDS": str(self.timeouts["checks_minutes"] * 60),
            "TIPS_TEAM_CONFIG": str(self.config_path),
        }
        if "compaction_percent" in self.role:
            self.target_env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] = str(
                self.role["compaction_percent"]
            )
        if os.environ.get("HERDR_ENV") != "1":
            raise RefusalError("Run the worktree helper inside Herdr.")

    def role_key(self) -> str:
        if not self.args.ui:
            return self.role_name
        if self.role_name != "lead":
            raise RefusalError("--ui applies only to the lead role.")
        if "lead_ui" not in self.config["roles"]:
            raise RefusalError("roles.lead_ui is not configured.")
        return "lead_ui"

    def check_settings(self) -> None:
        if self.kind not in ("codex", "claude") or (self.args.kind and self.args.kind != self.kind):
            raise RefusalError("--kind must match the configured role.kind.")
        if not 1 <= self.args.team <= self.team["max_teams"]:
            raise RefusalError(f"Team must be between 1 and {self.team['max_teams']}.")
        if self.timeouts["mcp_tool_seconds"] != 120:
            raise RefusalError(
                "The patched bridge has a compiled 120-second deadline. "
                "Rebuild and revalidate it before changing mcp_tool_seconds."
            )

    def resolve_worktree(self) -> None:
        self.issue = self.args.task.split("-", 1)[0]
        self.worktree = self.root / ".worktrees" / self.args.task
        self.branch = "task/" + self.args.task
        self.existing_branch = False
        if not self.args.review_ref:
            branches = git(
                "for-each-ref", "--format=%(refname:short)", f"refs/heads/task/{self.issue}-*"
            ).splitlines()
            if len(branches) > 1:
                raise RefusalError(f"Ambiguous task branches for issue {self.issue}: {branches}")
            if branches:
                self.existing_branch = True
                self.branch = branches[0]
                records = [
                    dict(line.split(" ", 1) for line in block.splitlines() if " " in line)
                    for block in git("worktree", "list", "--porcelain").split("\n\n")
                ]
                matches = [
                    Path(record["worktree"])
                    for record in records
                    if record.get("branch") == "refs/heads/" + self.branch
                ]
                if len(matches) > 1:
                    raise RefusalError(f"Ambiguous worktrees for {self.branch}: {matches}")
                self.worktree = (
                    matches[0]
                    if matches
                    else self.root / ".worktrees" / self.branch.removeprefix("task/")
                )
                if self.worktree.parent != self.root / ".worktrees":
                    raise RefusalError(
                        "Task branch belongs to a worktree outside the managed directory: "
                        f"{self.worktree}"
                    )

    def check_tools(self) -> None:
        self.wrapper = self.root / "agent/lsp/launch_worktree_lsp.sh"
        if not self.wrapper.is_file() or not (self.root / ".agents/skills").is_dir():
            raise RefusalError("Canonical LSP wrapper or shared skills directory is missing.")
        if self.args.start:
            tools = (
                Path(os.environ.get("TIPS_ELIXIR_TOOLS", str(self.root / "agent/lsp/vendor")))
                / "bin"
            )
            for binary in ("mcp-language-server", "expert"):
                if not os.access(tools / binary, os.X_OK):
                    raise RefusalError(
                        f"Missing executable: {tools / binary}; run tool preflight first."
                    )

    def inspect_worktree(self) -> None:
        self.review_sha = (
            git("rev-parse", "--verify", "--end-of-options", self.args.review_ref + "^{commit}")
            if self.args.review_ref
            else None
        )
        self.old_head = None
        if self.worktree.exists():
            if (
                Path(git("-C", self.worktree, "rev-parse", "--show-toplevel")) != self.worktree
                or Path(
                    git(
                        "-C",
                        self.worktree,
                        "rev-parse",
                        "--path-format=absolute",
                        "--git-common-dir",
                    )
                )
                != self.root / ".git"
            ):
                raise RefusalError(f"Not this repository's worktree: {self.worktree}")
            current_branch = git("-C", self.worktree, "branch", "--show-current")
            if self.review_sha:
                if current_branch:
                    raise RefusalError(f"Refusing an attached review checkout: {self.worktree}")
                if git("-C", self.worktree, "status", "--porcelain", "--untracked-files=all"):
                    raise RefusalError(f"Refusing a dirty review checkout: {self.worktree}")
            elif current_branch != self.branch:
                raise RefusalError(f"Worktree is not on {self.branch}: {self.worktree}")
            self.old_head = git("-C", self.worktree, "rev-parse", "HEAD")

    def prepare_config(self) -> None:
        if self.kind == "codex":
            config = f"""[plugins."mix-compile@elixir-agent-tools"]
enabled = true
[plugins."mix-credo@elixir-agent-tools"]
enabled = true

[mcp_servers.elixir-lsp]
command = "/bin/sh"
args = {json.dumps([str(self.wrapper), str(self.worktree)], ensure_ascii=False)}
cwd = {json.dumps(str(self.worktree), ensure_ascii=False)}
startup_timeout_sec = {self.timeouts["mcp_startup_seconds"]}
tool_timeout_sec = {self.timeouts["mcp_tool_seconds"]}
enabled_tools = ["definition", "references", "hover", "diagnostics"]
"""
            for tool in ("definition", "references", "hover", "diagnostics"):
                config += (
                    f"\n[mcp_servers.elixir-lsp.tools.{tool}]\n"
                    f"approval_mode = {json.dumps(self.policies['codex_lsp_approval_mode'])}\n"
                )
            self.desired = {self.worktree / ".codex/config.toml": config}
        else:
            self.desired = {
                self.worktree / ".claude/settings.local.json": json.dumps(
                    {
                        "enabledPlugins": {
                            "mix-compile@elixir-agent-tools": True,
                            "mix-credo@elixir-agent-tools": True,
                            "elixir-lsp@elixir-agent-tools": False,
                        }
                    },
                    indent=2,
                )
                + "\n",
                self.worktree / ".claude/elixir-mcp.json": json.dumps(
                    {
                        "mcpServers": {
                            "elixir-lsp": {
                                "type": "stdio",
                                "command": "/bin/sh",
                                "args": [str(self.wrapper), str(self.worktree)],
                                "timeout": self.timeouts["mcp_tool_seconds"] * 1000,
                            }
                        }
                    },
                    indent=2,
                )
                + "\n",
            }

    def check_target_tree(self) -> None:
        if not self.worktree.exists() and (not self.review_sha) and (not self.existing_branch):
            git("fetch", "origin")
        self.target_tree = git(
            "rev-parse",
            self.review_sha
            or self.old_head
            or (self.branch if self.existing_branch else "origin/main"),
        )
        selected = [path.relative_to(self.worktree).as_posix() for path in self.desired] + [
            ".agents/skills"
        ]
        for relative in selected:
            if git("ls-tree", self.target_tree, "--", relative):
                raise RefusalError(
                    f"Requested revision tracks generated path {relative}; preserving checkout."
                )
            parent = str(Path(relative).parent)
            entry = git("ls-tree", self.target_tree, "--", parent)
            if entry and (not entry.startswith("040000 tree ")):
                raise RefusalError(
                    f"Requested revision has a non-directory at {parent}; preserving checkout."
                )

    def check_config_files(self) -> None:
        # Preflight selected files before stopping a client or changing HEAD.
        self.changed = []
        for path, content in self.desired.items():
            if path.is_symlink() or path.parent.is_symlink():
                raise RefusalError(f"Refusing symlinked client configuration: {path}")
            if path.exists() and path.read_text() != content and (not self.args.force):
                raise RefusalError(
                    f"Refusing to overwrite {path}; inspect it before using --force."
                )
            if not path.exists() or path.read_text() != content:
                self.changed.append(path)
        self.skills = self.worktree / ".agents/skills"
        if self.skills.exists() and (not self.skills.is_symlink()):
            raise RefusalError(f"Refusing to replace existing skills: {self.skills}")

    def find_owner(self) -> None:
        agents = self.herdr("agent", "list")["agents"]
        self.owner = None
        for agent in agents:
            agent_root = agent.get("foreground_cwd") or agent.get("cwd")
            self.check_teammate(agent, agent_root)
            relevant = (
                agent.get("pane_id") == self.args.pane
                or agent.get("name") == self.agent_name
                or agent_root == str(self.worktree)
            )
            if not relevant:
                continue
            if (
                agent.get("pane_id") != self.args.pane
                or agent_root != str(self.worktree)
                or agent.get("agent") != self.kind
                or (agent.get("name") not in (None, self.agent_name))
            ):
                raise RefusalError(
                    f"Conflicting live agent: {agent.get('name') or agent.get('pane_id')} "
                    f"at {agent_root}"
                )
            self.owner = agent

    def check_teammate(self, agent: Entity, agent_root: str | None) -> None:
        teammate = re.fullmatch(
            "team-" + str(self.args.team) + "-(dev|lead|test)", agent.get("name") or ""
        )
        if teammate:
            teammate_issue = re.match("([0-9]+)-", Path(agent_root or "").name)
            if not teammate_issue or teammate_issue.group(1) != self.issue:
                raise RefusalError(
                    f"Team {self.args.team} already has a coding agent "
                    "on another or unknown issue: "
                    f"{agent.get('name')} at {agent_root}"
                )

    def reuse_or_stop_owner(self) -> bool:
        if self.owner is None:
            return False
        if not self.old_head:
            raise RefusalError("Live session has no matching Git worktree.")
        if self.changed:
            raise RefusalError(
                "Client configuration changed while its session is running; "
                "stop it before reconfiguring."
            )
        if not self.review_sha or self.review_sha == self.old_head:
            return self.reuse_running(self.owner)
        if self.role_name == "lead":
            return self.advance_in_place()
        if not self.args.start:
            raise RefusalError(
                "A reviewer is running; use --start to stop it safely "
                "before advancing its revision."
            )
        stop_agent(self.args.pane, str(self.worktree))
        # A final save during shutdown must block checkout advancement.
        if git("-C", self.worktree, "status", "--porcelain", "--untracked-files=all"):
            raise RefusalError("Review checkout became dirty during shutdown; preserving it.")
        return False

    def reuse_running(self, owner: Entity) -> bool:
        if owner.get("agent_status") in ("blocked", "unknown"):
            raise RefusalError(
                f"Existing session is {owner.get('agent_status')}; inspect its pane."
            )
        if self.args.start and (not owner.get("name")):
            self.herdr("agent", "rename", self.args.pane, self.agent_name)
        print(
            f"Already running: {self.agent_name} in {self.worktree} ({owner.get('agent_status')})"
        )
        return True

    def advance_in_place(self) -> bool:
        """The lead stays through the issue; move its clean detached checkout to the new SHA."""
        if self.owner is not None and self.owner.get("agent_status") in ("blocked", "unknown"):
            raise RefusalError(
                f"Lead session is {self.owner.get('agent_status')}; inspect its pane."
            )
        if not self.review_sha:
            raise RefusalError("A running lead advances only to an explicit --review-ref.")
        git("-C", self.worktree, "checkout", "--detach", "--no-overwrite-ignore", self.review_sha)
        print(f"Advanced {self.agent_name} in place: {self.worktree} at {self.review_sha}")
        return True

    def check_shell(self) -> None:
        if self.args.start or (
            self.old_head and self.review_sha and (self.old_head != self.review_sha)
        ):
            info = self.herdr("pane", "process-info", "--pane", self.args.pane)["process_info"]
            foreground = info.get("foreground_processes", [])
            if not foreground or any(p["pid"] != info["shell_pid"] for p in foreground):
                raise RefusalError(
                    "Target pane is not at its shell; nothing will be launched there."
                )

    def checkout(self) -> None:
        if not self.worktree.exists():
            if self.review_sha:
                git("worktree", "add", "--detach", self.worktree, self.review_sha)
            elif self.existing_branch:
                git("worktree", "add", self.worktree, self.branch)
            else:
                git(
                    "worktree",
                    "add",
                    "--no-track",
                    "-b",
                    self.branch,
                    self.worktree,
                    self.target_tree,
                )
        elif self.review_sha and self.old_head != self.review_sha:
            git(
                "-C",
                self.worktree,
                "checkout",
                "--detach",
                "--no-overwrite-ignore",
                self.review_sha,
            )

    def write_config(self) -> None:
        for path, content in self.desired.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists() and path.read_text() == content:
                continue
            if path.exists() and (not self.args.force):
                raise RefusalError(f"Checkout introduced a conflicting config; preserving {path}")
            with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
                temp = Path(stream.name)
                stream.write(content)
            try:
                temp.replace(path)
            finally:
                temp.unlink(missing_ok=True)

    def link_skills(self) -> None:
        self.skills.parent.mkdir(parents=True, exist_ok=True)
        shared_skills = self.root / ".agents/skills"
        if not self.skills.is_symlink() or os.readlink(self.skills) != str(shared_skills):
            self.skills.unlink(missing_ok=True)
            self.skills.symlink_to(shared_skills)

    def launch(self) -> None:
        # Herdr runs separately: exports must execute in the target pane.
        marker = "TIPS_TASK_READY_" + uuid.uuid4().hex
        setup = (
            "cd -- "
            + shlex.quote(str(self.worktree))
            + " && export "
            + " ".join((shlex.quote(k + "=" + v) for k, v in self.target_env.items()))
        )
        if "compaction_percent" not in self.role:
            setup += " && unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
        setup += " && printf '\\n%s%s\\n' " + shlex.join([marker[:16], marker[16:]])
        self.herdr("pane", "run", self.args.pane, setup)
        self.herdr(
            "pane",
            "wait-output",
            self.args.pane,
            "--match",
            marker,
            "--source",
            "detection",
            "--timeout",
            self.timeouts["shell_seconds"] * 1000,
        )
        client: list[str] = []
        if self.kind == "codex":
            client += ["-a", self.policies["codex_approval"], "-C", str(self.worktree)]
            if self.model:
                client += ["-m", self.model]
            client += ["-c", "model_reasoning_effort=" + json.dumps(self.effort)]
        else:
            client += [
                "--permission-mode",
                self.policies["claude_permission_mode"],
                "--effort",
                self.effort,
                "--mcp-config",
                str(self.worktree / ".claude/elixir-mcp.json"),
            ]
            if self.model:
                client += ["--model", self.model]
        self.herdr(
            "agent",
            "start",
            self.agent_name,
            "--kind",
            self.kind,
            "--pane",
            self.args.pane,
            "--timeout",
            self.timeouts["launch_seconds"] * 1000,
            "--",
            *client,
            timeout=self.timeouts["launch_seconds"],
        )
        started = self.herdr("agent", "get", self.args.pane)["agent"]
        if (
            (started.get("foreground_cwd") or started.get("cwd")) != str(self.worktree)
            or started.get("agent") != self.kind
            or started.get("name") != self.agent_name
            or (started.get("agent_status") in ("blocked", "unknown"))
        ):
            raise RefusalError(
                "Client started in an unexpected state/root; inspect its pane before proceeding."
            )
        print(
            "Launched "
            f"{self.agent_name}"
            ": "
            f"{started['agent_status']}"
            ", "
            f"{self.kind}"
            ", "
            f"{self.worktree}"
            ". Project compilation may still be running."
        )

    def herdr(self, *parts: str | int, timeout: float | None = None) -> HerdrResult:
        text = run(["herdr", *map(str, parts)], timeout=timeout or self.timeouts["shell_seconds"])
        if parts[:2] == ("pane", "run"):
            return cast(HerdrResult, {})
        return parse_herdr(text)


def main() -> None:
    task = WorktreeTask(parse_arguments())
    task.resolve_worktree()
    task.check_tools()
    task.inspect_worktree()
    task.prepare_config()
    task.check_target_tree()
    task.check_config_files()
    task.find_owner()
    if task.reuse_or_stop_owner():
        return
    task.check_shell()
    task.checkout()
    task.write_config()
    task.link_skills()
    print(f"Worktree: {task.worktree}")
    if task.args.start:
        task.launch()
    else:
        print("Provisioned; use --start to launch this configured role.")


if __name__ == "__main__":
    try:
        main()
    except (
        RefusalError,
        RuntimeError,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"Worktree setup failed: {error}", file=sys.stderr)
        sys.exit(1)
