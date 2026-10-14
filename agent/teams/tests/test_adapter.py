"""The dispatcher adapter over real MCP stdio, with fake Herdr, gh, Git hosting and clients.

Needs the locked adapter environment (requirements.lock); CI installs it. Without the MCP
SDK these tests are skipped and say so.
"""

import asyncio
import importlib.util
import json
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
    "remove_empty_residue",
    "pr_state",
    "pr_checks",
    "pr_list",
    "pr_read",
    "issue_read",
    "issue_create",
    "board_read",
    "board_post",
    "usage_summary",
    "wait_for_team",
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
if a[0] == "api" and a[1] != "--paginate":
    # Comment reads by page or by id, as pending.py makes them.
    s.setdefault("events", []).append(["gh", *a])
    path.write_text(json.dumps(s))
    route, _, query = a[1].partition("?")
    parts = route.split("/")
    def located(number, comment):
        return {**comment, "issue_url": "https://api.github.com/repos/o/r/issues/" + number}
    stored = s.get("comments", {})
    if parts[-2] == "comments":
        found = [located(n, c) for n, cs in stored.items() for c in cs if str(c["id"]) == parts[-1]]
        if not found:
            sys.exit("gh: Not Found (HTTP 404)")
        print(json.dumps(found[0]))
    else:
        params = dict(pair.split("=") for pair in query.split("&"))
        size, page = int(params["per_page"]), int(params["page"])
        page_items = stored.get(parts[-2], [])[(page - 1) * size : page * size]
        print(json.dumps([located(parts[-2], c) for c in page_items]))
    sys.exit(0)
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
        for name in ("adapter.py", "pending.py", "pr_review.py"):
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

    def request(self, issue: int, kind: str, name: str) -> int:
        """Post a worker's request comment to the fixture as board.py would; return its id."""
        state = self.state()
        comments = state.setdefault("comments", {})
        number = sum(len(c) for c in comments.values()) + 1
        body = f"{kind} implementer {name} worker-session\n{kind.lower()} {number}"
        url = f"https://github.com/o/r/issues/{issue}#issuecomment-{number}"
        created = "2026-10-14T10:00:00Z"
        comment = {"id": number, "html_url": url, "body": body, "created_at": created}
        comments.setdefault(str(issue), []).append(comment)
        self.update(comments=comments)
        return number

    @staticmethod
    async def wait(client: Any) -> dict[str, Any]:
        text = await AdapterTest.call(client, "wait_for_team", timeout=0)
        return json.loads(text)

    @staticmethod
    def ids(found: dict[str, Any], key: str = "requests") -> list[int]:
        return [item["comment_id"] for item in found.get(key, [])]

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

    def test_a_request_stays_open_until_an_action_record_names_it(self) -> None:
        async def idle(client: Any) -> None:
            found = await self.wait(client)
            assert found == {"result": "idle", "watched": [], "github_requests": 0}, found
            await self.call(client, "start_pair", brief=29)

        self.session(idle)
        # Two independent requests on one thread.
        blocked = self.request(29, "BLOCKED", "team-1-impl")
        done = self.request(29, "DONE", "team-1-tester")

        async def act(client: Any) -> None:
            found = await self.wait(client)
            assert found["result"] == "requests"
            assert self.ids(found) == [blocked, done]
            assert found["github_requests"] == 1
            # An unrelated dispatcher comment handles nothing.
            await self.call(client, "board_post", issue=29, comment_type="EVENT", body="note")
            assert self.ids(await self.wait(client)) == [blocked, done]
            # An action names only one of the two.
            answer: dict[str, Any] = {"issue": 29, "comment_type": "ANSWER", "body": "Use X."}
            await self.call(client, "board_post", **answer, answers=[blocked])
            found = await self.wait(client)
            assert self.ids(found) == [done]
            # Delivery only: recorded pending, so it waits for an outcome, not for action.
            prompt: dict[str, Any] = {"brief": 29, "entry": "tester", "text": "Merged?"}
            await self.call(client, "prompt_agent", **prompt, answers=[done])
            found = await self.wait(client)
            assert found["result"] == "timeout"
            assert self.ids(found, "awaiting_outcome") == [done]
            # Answers must be worker requests, and a post answers only its own issue.
            refused = await self.call(client, "board_post", ok=False, **answer, answers=[1])
            assert "not a worker BLOCKED or DONE request" in refused
            other: dict[str, Any] = {"issue": 30, "comment_type": "ANSWER", "body": "No."}
            await self.call(client, "board_post", ok=False, **other, answers=[done])

        self.session(act)
        later = self.request(29, "BLOCKED", "team-1-impl")

        async def restart(client: Any) -> None:
            # A new adapter reads the same records: the request after the action is open.
            found = await self.wait(client)
            assert self.ids(found) == [later]
            assert self.ids(found, "awaiting_outcome") == [done]
            # A failed action leaves the request open and says so.
            failed = await self.call(
                client, "prompt_agent", ok=False, brief=29, entry="ghost", text="x", answers=[later]
            )
            assert "no launched ghost" in failed
            found = await self.wait(client)
            assert found["requests"][0]["last_action"] == "failed"
            await self.call(client, "retire_team", ok=False, brief=29, answers=[later])
            assert self.ids(await self.wait(client)) == [later]

        self.session(restart)
        records = [c["body"] for c in self.state()["comments"]["29"] if "TEAM_ACTION" in c["body"]]
        assert len(records) == 4, records
        assert records[0].startswith("ANSWER dispatcher dispatcher dispatcher-session\nUse X.")
        assert f'"sources": [{done}], "state": "pending"' in records[1]
        assert f'"sources": [{later}], "state": "failed"' in records[2]
        assert records[1].startswith("EVENT dispatcher dispatcher dispatcher-session\n")
        # Exactly one prompt reached Herdr; the refused and failed actions sent nothing.
        prompts = [e for e in self.state()["events"] if e[:2] == ["agent", "prompt"]]
        assert [e[3] for e in prompts].count("Merged?") == 1, prompts
        assert all(e[3] != "x" for e in prompts), prompts
