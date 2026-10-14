"""The dispatcher adapter over real MCP stdio, with fake Herdr, gh, Git hosting and clients.

Needs the locked adapter environment (requirements.lock); CI installs it. Without the MCP
SDK these tests are skipped and say so.
"""

import asyncio
import importlib.util
import os
import sys
import unittest
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from tests.test_team import CONFIG, FAKE_GH, Harness

TEAMS = Path(__file__).resolve().parents[1]
HAS_SDK = importlib.util.find_spec("mcp") is not None
NO_SDK = "MCP SDK missing: install agent/teams/requirements.lock (development.md)"
GITHUB = """
[github]
repository = "o/r"

[github.projects]
16 = ["Phase", "Feature"]
"""
TOOLS = {
    "status",
    "start_pair",
    "launch_reviewer",
    "start_design",
    "prompt_agent",
    "retire_team",
    "pr_state",
    "pr_checks",
    "pr_list",
    "pr_read",
    "issue_read",
    "issue_create",
    "board_read",
    "board_post",
    "usage_summary",
    "project_read",
    "project_add_item",
    "project_set_field",
}

# GitHub operations the adapter adds; everything else goes to the shared fake.
ADAPTER_GH = r"""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
a = sys.argv[1:]
path = Path(os.environ["HERDR_FIXTURE"])
s = json.loads(path.read_text())
base = str(Path(sys.argv[0]).with_name("gh-base"))
if a[:2] == ["pr", "view"] and "state" in a[a.index("--json") + 1]:
    pass
elif a[:2] not in (["issue", "create"], ["pr", "checks"], ["pr", "list"]) and a[0] != "project":
    os.execv(base, [base, *a])
s.setdefault("events", []).append(["gh", *a])
path.write_text(json.dumps(s))
if a[:2] == ["issue", "create"]:
    time.sleep(float(s.get("gh_sleep", 0)))
    print("https://github.com/o/r/issues/500")
elif a[:2] == ["pr", "view"]:
    print(json.dumps({"number": int(a[2]), "state": s.get("pr_state", "OPEN"),
                      "headRefOid": s.get("pr_head", ""), "mergeable": "MERGEABLE"}))
elif a[:2] == ["pr", "checks"]:
    print(json.dumps([{"name": "checks", "state": "PENDING", "bucket": "pending", "link": "L"}]))
    sys.exit(8)
elif a[:2] == ["pr", "list"]:
    print(json.dumps([{"number": 7, "title": "Brief 29", "state": "OPEN"}]))
elif a[1] == "view":
    print(json.dumps({"id": "PVT_16"}))
elif a[1] == "field-list":
    phase = {"id": "F_phase", "name": "Phase", "options": [{"id": "O_impl", "name": "Implement"}]}
    print(json.dumps({"fields": [phase, {"id": "F_feature", "name": "Feature"}]}))
elif a[1] == "item-list":
    print(json.dumps({"items": s.get("items", [])}))
elif a[1] in ("item-add", "item-edit"):
    print(json.dumps({"id": "I_new"}))
"""


@unittest.skipUnless(HAS_SDK, NO_SDK)
class AdapterTest(Harness):
    def setUp(self) -> None:
        super().setUp()
        for name in ("adapter.py", "pr_review.py"):
            (self.repo / "agent/teams" / name).write_text((TEAMS / name).read_text())
        config = CONFIG.replace("checks_minutes = 30", "checks_minutes = 30\ngithub_seconds = 2")
        (self.repo / "agent/teams/config.toml").write_text(config + GITHUB)
        self.commit("adapter")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        (self.bin / "gh-base").write_text(FAKE_GH)
        (self.bin / "gh").write_text(ADAPTER_GH)
        for name in ("gh", "gh-base"):
            (self.bin / name).chmod(0o755)

    def session(self, steps: Callable[[Any], Awaitable[None]]) -> None:
        """Start the adapter as the dispatcher's client would and run steps against it."""
        from mcp.client.session import ClientSession
        from mcp.client.stdio import StdioServerParameters, stdio_client

        env = {
            **self.env,
            "TIPS_DISPATCHER_SESSION": "dispatcher-session",
            # A cwd-relative PATH entry and Python path injection must not reach commands.
            "PATH": "relative-bin" + os.pathsep + self.env["PATH"],
            "PYTHONPATH": str(self.root),
        }
        params = StdioServerParameters(
            command=sys.executable,
            args=["-E", "-s", str(self.repo / "agent/teams/adapter.py")],
            env=env,
            cwd=str(self.root),
        )

        async def run() -> None:
            async with stdio_client(params) as (read, write), ClientSession(read, write) as client:
                await client.initialize()
                await steps(client)

        asyncio.run(run())

    @staticmethod
    async def call(client: Any, name: str, ok: bool = True, **arguments: Any) -> str:
        result = await client.call_tool(name, arguments)
        text = "".join(part.text for part in result.content)
        assert result.is_error != ok, f"{name} {arguments}: {text}"
        return text

    def test_tools_are_the_fixed_inventory_and_reject_malformed_requests(self) -> None:
        async def steps(client: Any) -> None:
            tools = (await client.list_tools()).tools
            assert {tool.name for tool in tools} == TOOLS
            for tool in tools:
                names = set(tool.input_schema.get("properties", {}))
                assert not names & {"path", "command", "cmd", "args", "profile", "cwd", "pane"}
            refused = await self.call(client, "status", ok=False, path="/etc/hosts")
            assert "does not accept path" in refused
            await self.call(client, "start_pair", ok=False, brief="../29")
            await self.call(client, "launch_reviewer", ok=False, pr=7, entry="Bad Entry")
            unknown = await self.call(
                client, "prompt_agent", ok=False, brief=29, entry="ghost", text="hi"
            )
            assert "no allocation record" in unknown
            post: dict[str, Any] = {"issue": 29, "comment_type": "SHELL", "body": "x"}
            await self.call(client, "board_post", ok=False, **post)
            await self.call(client, "pr_list", ok=False, state="draft")
            status: dict[str, Any] = {"project": 16, "issue": 29, "field": "Status"}
            field = await self.call(client, "project_set_field", ok=False, **status, value="Done")
            assert "not approved" in field
            other = await self.call(client, "project_read", ok=False, project=15)
            assert "not configured" in other
            design = await self.call(
                client, "start_design", ok=False, spec=40, entry="critic", lead=True
            )
            assert "#441" in design

        self.session(steps)
        assert not self.events("agent", "start")
        assert not [e for e in self.state()["events"] if e[:3] == ["gh", "project", "item-edit"]]

    def test_pair_review_prompt_status_and_retirement_through_the_adapter(self) -> None:
        async def launch(client: Any) -> None:
            assert "No allocation records" in await self.call(client, "status")
            await self.call(client, "start_pair", brief=29)
            status = await self.call(client, "status")
            assert "impl (implementer, codex) team-1-impl: running" in status, status
            assert "dispatcher: not running" in status
            await self.call(client, "prompt_agent", brief=29, entry="tester", text="Your turn")

        self.session(launch)
        assert ["agent", "prompt", "team-1-tester", "Your turn"] in self.state()["events"]
        wt = self.worktree("29")
        head = self.push(wt)

        async def review(client: Any) -> None:
            await self.call(client, "launch_reviewer", pr=7, entry="critic")
            state = await self.call(client, "pr_state", pr=7)
            assert head in state
            assert '"bucket": "pending"' in state

        self.session(review)
        assert self.pane("team-1-critic")["agent"] == "claude"
        self.git("merge", "-q", "--no-ff", "-m", "merge 29", "task/29")
        self.clients_exit(1)

        async def retire(client: Any) -> None:
            status = await self.call(client, "status")
            assert "at the shell, client exited" in status, status
            await self.call(client, "retire_team", brief=29)

        self.session(retire)
        assert not wt.exists()
        assert not (self.repo / "agent/teams/allocations/1.json").exists()

    def test_board_issue_and_project_writes_name_the_repository_and_dispatcher(self) -> None:
        content = {"number": 29, "url": "https://github.com/o/r/issues/29"}
        item = {"id": "I_29", "title": "Brief", "phase": "Design", "content": content}
        self.update(items=[item])

        async def steps(client: Any) -> None:
            url = await self.call(
                client, "board_post", issue=29, comment_type="EVENT", body="launched claude"
            )
            assert url.endswith("#issuecomment-1")
            board = await self.call(client, "board_read", issue=29)
            assert "EVENT dispatcher dispatcher dispatcher-session\nlaunched claude" in board
            items = await self.call(client, "project_read", project=16)
            assert "#29 Brief | Phase: Design" in items
            phase: dict[str, Any] = {"project": 16, "issue": 29, "field": "Phase"}
            await self.call(client, "project_set_field", **phase, value="Implement")
            missing = await self.call(
                client, "project_set_field", ok=False, **phase, value="Shipped"
            )
            assert "options: Implement" in missing

        self.session(steps)
        calls = [e[1:] for e in self.state()["events"] if e[0] == "gh"]
        assert ["issue", "comment", "29", "--repo", "o/r", "--body-file", "-"] in calls
        target = ["--id", "I_29", "--project-id", "PVT_16", "--field-id", "F_phase"]
        assert ["project", "item-edit", *target, "--single-select-option-id", "O_impl"] in calls
        assert all(c[:2] != ["repo", "view"] for c in calls)

    def test_timeout_after_an_issue_create_reports_ambiguity_and_does_not_repeat(self) -> None:
        self.update(gh_sleep=5)

        async def steps(client: Any) -> None:
            error = await self.call(client, "issue_create", ok=False, title="Spec", body="Body")
            assert "may have reached GitHub" in error
            assert "do not repeat it blindly" in error

        self.session(steps)
        creates = [e for e in self.state()["events"] if e[:3] == ["gh", "issue", "create"]]
        create = ["issue", "create", "--repo", "o/r", "--title", "Spec", "--body-file", "-"]
        assert creates == [["gh", *create]]

