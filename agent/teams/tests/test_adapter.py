"""The dispatcher adapter over real MCP stdio, with fake Herdr, gh, Git hosting and clients.

Needs the locked adapter environment (requirements.lock); CI installs it. Without the MCP
SDK these tests are skipped and say so.
"""

import asyncio
import importlib.util
import json
import os
import re
import shutil
import sys
import unittest
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from tests.harness import CONFIG, Harness, fake

TEAMS = Path(__file__).resolve().parents[1]
HAS_SDK = importlib.util.find_spec("mcp") is not None
NO_SDK = "MCP SDK missing: install agent/teams/requirements.lock (development.md)"
TOOLS = {
    "status",
    "start_pair",
    "launch_reviewer",
    "start_design",
    "prompt_agent",
    "retire_team",
    "pr_state",
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
pairs = [a[i : i + 2] for i in range(len(a))]
if a[0] in ("pr", "issue") and ["--repo", "o/r"] not in pairs:
    sys.exit("fixture gh: no --repo o/r in " + repr(a))
if a[0] == "project" and a[1] != "item-edit" and ["--owner", "o"] not in pairs:
    sys.exit("fixture gh: no --owner o in " + repr(a))
path = Path(os.environ["HERDR_FIXTURE"])
s = json.loads(path.read_text())
base = str(Path(sys.argv[0]).with_name("gh-base"))
if a[:2] == ["issue", "view"] and "title" in a[a.index("--json") + 1]:
    body = s.get("issues", {}).get(a[2], "")
    view = {"number": int(a[2]), "title": "Brief", "state": "OPEN", "labels": [],
            "url": "https://github.com/o/r/issues/" + a[2], "body": body}
    print(json.dumps({key: view[key] for key in a[a.index("--json") + 1].split(",")}))
    sys.exit(0)
if a[:2] == ["pr", "view"] and "mergeStateStatus" in a[a.index("--json") + 1]:
    pass
elif a[:2] not in (["issue", "create"], ["pr", "list"]) and a[0] != "project":
    os.execv(base, [base, *a])
s.setdefault("events", []).append(["gh", *a])
path.write_text(json.dumps(s))
if a[:2] == ["issue", "create"]:
    time.sleep(float(s.get("gh_sleep", 0)))
    print("https://github.com/o/r/issues/500")
elif a[:2] == ["pr", "view"]:
    closing = [{"number": 29}] * int(s.get("closing_count", 1))
    print(json.dumps({"number": int(a[2]), "state": s.get("pr_state", "OPEN"),
                      "headRefOid": s.get("pr_head", ""), "mergeable": "MERGEABLE",
                      "closingIssuesReferences": closing}))
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

# Logs each git call's working directory and arguments, then runs the real git.
LOGGING_GIT = """#!/usr/bin/env python3
import json, os, sys
with open(%r, "a") as log:
    log.write(json.dumps([os.getcwd(), *sys.argv[1:]]) + "\\n")
os.execv(%r, [%r, *sys.argv[1:]])
"""


@unittest.skipUnless(HAS_SDK, NO_SDK)
class AdapterTest(Harness):
    def setUp(self) -> None:
        super().setUp()
        (self.repo / "agent/teams/adapter.py").write_text((TEAMS / "adapter.py").read_text())
        self.write_config(self.github_config(10))
        self.commit("adapter")
        self.git("push", "-q", "origin", "main")
        (self.bin / "gh").rename(self.bin / "gh-base")
        (self.bin / "gh").symlink_to(fake("adapter-gh", ADAPTER_GH))
        git = shutil.which("git", path=self.env["PATH"])
        assert git
        self.git_log = self.root / "git-calls"
        self.adapter_bin = self.root / "adapter-bin"
        self.adapter_bin.mkdir()
        (self.adapter_bin / "git").write_text(LOGGING_GIT % (str(self.git_log), git, git))
        (self.adapter_bin / "git").chmod(0o755)

    @staticmethod
    def github_config(seconds: int) -> str:
        """The fixture config with a GitHub deadline; 10 s survives a loaded parallel run."""
        timeouts = f"checks_minutes = 30\ngithub_seconds = {seconds}"
        return CONFIG.replace("checks_minutes = 30", timeouts)

    def session(self, steps: Callable[[Any], Awaitable[None]]) -> None:
        """Start the adapter as the dispatcher's client would and run steps against it."""
        from mcp.client.session import ClientSession
        from mcp.client.stdio import StdioServerParameters, stdio_client

        # A cwd-relative PATH entry and Python path injection must not reach commands. The
        # relative entry names a planted gh and git under the client's cwd and under the
        # main checkout (in its ignored tmp/); each records that it ran.
        marker = self.root / "relative-bin-ran"
        for cwd in (self.root, self.repo):
            planted = cwd / "tmp/relative-bin"
            planted.mkdir(parents=True, exist_ok=True)
            for name, real in (("gh", self.bin / "gh"), ("git", self.adapter_bin / "git")):
                script = f'#!/bin/sh\necho {name} >> "{marker}"\nexec "{real}" "$@"\n'
                (planted / name).write_text(script)
                (planted / name).chmod(0o755)
        env = {
            **self.env,
            "TIPS_DISPATCHER_SESSION": "dispatcher-session",
            "PATH": os.pathsep.join(("tmp/relative-bin", str(self.adapter_bin), self.env["PATH"])),
            "PYTHONPATH": str(self.root),
        }
        self.git_log.unlink(missing_ok=True)
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
        # In a worker's clone, whose .git/config and hooks the worker controls, the adapter
        # runs git only as retire_team's cleanup: from the state directory, hooks and
        # fsmonitor off, a fetch of origin or a read.
        calls = [json.loads(line) for line in self.git_log.read_text().splitlines()]
        assert calls  # the harness's own startup git ran through the wrapper
        allocations = str(self.trusted / "allocations")
        cleanup = [c for c in calls if any(allocations in part for part in c)]
        hooks_off = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]
        checks = (
            ["fetch", "--prune", "--quiet", "origin"],
            ["status", "--porcelain"],
            ["rev-list", "HEAD", "--branches", "--not", "--remotes=origin"],
            ["stash", "list"],
        )
        for call in cleanup:
            assert call[0] == str(self.trusted / "state"), call
            assert call[3:7] == hooks_off, call
            assert call[7:] in checks, call
        assert not marker.exists(), f"a cwd-relative PATH entry ran: {marker.read_text()}"
        # Startup git runs from the client's cwd; every later command from the main checkout.
        cwds = [c[0] for c in calls[1:] if c not in cleanup]
        assert all(cwd == str(self.repo) for cwd in cwds), f"ran outside the checkout: {cwds}"

    @staticmethod
    async def call(client: Any, name: str, ok: bool = True, **arguments: Any) -> str:
        result = await client.call_tool(name, arguments)
        text = "".join(part.text for part in result.content)
        assert result.is_error != ok, f"{name} {arguments}: {text}"
        return text

    def test_tools_are_the_fixed_inventory_and_reject_malformed_requests(self) -> None:
        ready = self.trusted / "state/dispatcher.ready"

        async def steps(client: Any) -> None:
            assert not ready.exists()
            tools = (await client.list_tools()).tools
            assert {tool.name for tool in tools} == TOOLS
            # Listing the tools tells the launcher this session's client has them.
            assert json.loads(ready.read_text())["session"] == "dispatcher-session"
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
            design = await self.call(client, "start_design", ok=False, spec=40, entry="impl")
            assert "not a configured designer entry" in design

        self.session(steps)
        assert not self.events("agent", "start")
        assert not [e for e in self.state()["events"] if e[:3] == ["gh", "project", "item-edit"]]

    def test_design_pair_review_prompt_status_and_retirement_through_the_adapter(self) -> None:
        async def launch(client: Any) -> None:
            assert "No allocation records" in await self.call(client, "status")
            await self.call(client, "start_design", spec=40, entry="critic")
            await self.call(client, "start_pair", brief=29)
            status = await self.call(client, "status")
            assert "impl (implementer, codex) team-2-impl: running" in status, status
            assert "dispatcher: not running" in status
            await self.call(client, "prompt_agent", brief=29, entry="tester", text="Your turn")

        self.session(launch)
        assert ["agent", "prompt", "team-2-tester", "Your turn"] in self.state()["events"]
        # The adapter's launches ran no Git, Mix or Dexter step: each clone is the
        # client's own, prepared by its bootstrap.
        assert not self.events("mix")
        assert not self.events("dexter")
        for name in ("team-1-critic", "team-2-impl", "team-2-tester"):
            assert not any(self.project(name).iterdir()), name
        self.bootstrap("team-2-impl")
        self.bootstrap("team-2-tester")
        head = self.push("team-2-impl")
        mixes = len(self.events("mix"))  # the workers' own bootstraps

        async def review(client: Any) -> None:
            await self.call(client, "launch_reviewer", pr=7, entry="critic")
            state = await self.call(client, "pr_state", pr=7)
            assert head in state
            assert '"mergeable": "MERGEABLE"' in state
            assert "checks" not in state  # no required-checks call or message
            # A tool without an offset keeps a response prefix and says what it dropped.
            self.update(closing_count=1000)
            capped = await self.call(client, "pr_state", pr=7)
            assert "\n[truncated: " in capped, f"{len(capped.encode())} bytes returned uncapped"
            kept, notice = capped.rsplit("\n", 1)
            assert len(kept.encode()) == 8192, f"kept {len(kept.encode())} bytes, not 8192"
            assert head in kept, "the response prefix is lost"
            assert re.fullmatch(r"\[truncated: [1-9]\d* more bytes\]", notice), capped[-120:]

        self.session(review)
        assert len(self.events("mix")) == mixes
        assert not any(self.project("team-2-critic").iterdir())
        self.bootstrap("team-2-critic")

        async def unmerged(client: Any) -> None:
            refused = await self.call(client, "retire_team", ok=False, brief=29)
            assert "not closed by a merged PR" in refused

        self.session(unmerged)
        self.merge(head)
        self.clients_exit(2)

        async def second(client: Any) -> None:
            status = await self.call(client, "status")
            assert "at the shell, client exited" in status, status
            assert "slot 2 released" in await self.call(client, "retire_team", brief=29)

        self.session(second)
        assert self.recorded_briefs() == {"40"}

    def test_start_design_can_join_a_started_brief_without_a_spare_slot(self) -> None:
        self.write_config(CONFIG.replace("max_teams = 6", "max_teams = 1"))

        async def steps(client: Any) -> None:
            await self.call(client, "start_pair", brief=29)
            await self.call(client, "start_design", spec=29, entry="critic")
            await self.call(client, "prompt_agent", brief=29, entry="critic", text="Read QUESTION")

        self.session(steps)
        assert self.recorded_briefs() == {"29"}
        assert self.record(1)["kind"] == "brief"
        assert self.prompts("team-1-critic")[-1] == "Read QUESTION"

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
        # The fake must start and log its call within the deadline, even on a loaded machine.
        self.write_config(self.github_config(5))
        self.update(gh_sleep=10)

        async def steps(client: Any) -> None:
            error = await self.call(client, "issue_create", ok=False, title="Spec", body="Body")
            assert "may have reached GitHub" in error
            assert "do not repeat it blindly" in error

        self.session(steps)
        creates = [e for e in self.state()["events"] if e[:3] == ["gh", "issue", "create"]]
        create = ["issue", "create", "--repo", "o/r", "--title", "Spec", "--body-file", "-"]
        assert creates == [["gh", *create]]

    def test_board_read_after_a_comment_reaches_new_comments_on_a_long_issue(self) -> None:
        self.update(issues={"29": "spec " * 2000})

        async def steps(client: Any) -> None:
            await self.call(client, "board_post", issue=29, comment_type="EVENT", body="first")
            await self.call(client, "board_post", issue=29, comment_type="EVENT", body="second")
            full = await self.call(client, "board_read", issue=29)
            assert "[more: call again with offset=" in full
            later = await self.call(client, "board_read", issue=29, after_comment_id=1)
            assert "second" in later
            assert "first" not in later
            assert "spec spec" not in later

        self.session(steps)

    def test_real_github_comment_ids_are_accepted(self) -> None:
        async def steps(client: Any) -> None:
            await self.call(client, "board_read", issue=29, after_comment_id=6151732486)

        self.session(steps)

    def test_a_long_issue_body_continues_from_an_offset(self) -> None:
        self.update(issues={"29": "x" * 9000 + "TAIL"})

        async def steps(client: Any) -> None:
            for tool in ("issue_read", "board_read"):
                first = await self.call(client, tool, issue=29)
                assert "TAIL" not in first
                offset = int(first.rsplit("offset=", 1)[1].split("]")[0])
                rest = await self.call(client, tool, issue=29, offset=offset)
                assert "TAIL" in rest, tool
                assert len(first.encode()) <= 8192

        self.session(steps)

    def test_a_long_project_reads_to_the_end_without_done_items(self) -> None:
        def item(number: int) -> dict[str, Any]:
            status = "Done" if number % 3 == 0 else "Backlog"
            content = {"number": number, "url": f"https://github.com/o/r/issues/{number}"}
            fields = {"title": f"Issue {number}", "status": status, "phase": "Design"}
            return {"id": f"I_{number}", **fields, "content": content}

        self.update(items=[item(number) for number in range(1, 601)])
        pages: list[str] = []

        async def steps(client: Any) -> None:
            offset = 0
            while True:
                text = await self.call(client, "project_read", project=16, offset=offset)
                assert len(text.encode()) <= 8192
                pages.append(text)
                if "[more: call again with offset=" not in text:
                    return
                following = int(text.rsplit("offset=", 1)[1].split("]")[0])
                assert following > offset, f"page {len(pages)} points back to {following}"
                offset = following

        self.session(steps)
        assert len(pages) >= 3, len(pages)
        read = "".join(page.split("\n[more:")[0] for page in pages)
        assert "#599 Issue 599 | Phase: Design | Feature: " in read
        numbers = [int(line.split()[0][1:]) for line in read.splitlines()]
        assert numbers == [n for n in range(1, 601) if n % 3], "missing, repeated or Done items"

    def test_an_error_after_a_prompt_is_sent_is_reported_as_ambiguous(self) -> None:
        # Herdr reports its own timeout after the text may have reached the client.
        herdr = self.bin / "herdr"
        herdr.rename(self.bin / "herdr-base")
        herdr.write_text(
            "#!/bin/sh\n"
            'if [ "$1 $2" = "agent prompt" ] && [ -n "$PROMPT_ERROR" ]; then\n'
            '  "$(dirname "$0")/herdr-base" "$@" >/dev/null\n'
            '  echo \'{"error":{"code":"timeout","message":"request timed out"}}\' >&2\n'
            "  exit 1\n"
            "fi\n"
            'exec "$(dirname "$0")/herdr-base" "$@"\n'
        )
        herdr.chmod(0o755)

        async def launch(client: Any) -> None:
            await self.call(client, "start_pair", brief=29)

        self.session(launch)
        prompts = len(self.events("agent", "prompt"))
        self.env["PROMPT_ERROR"] = "1"

        async def prompt(client: Any) -> None:
            error = await self.call(
                client, "prompt_agent", ok=False, brief=29, entry="tester", text="Your turn"
            )
            assert "may have been delivered" in error, error
            assert "before sending it again" in error

        self.session(prompt)
        assert len(self.events("agent", "prompt")) == prompts + 1
