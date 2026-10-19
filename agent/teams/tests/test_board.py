"""The board script: attributed posts, reading after a checkpoint, and the usage table."""

import json
import subprocess
import unittest
from typing import Any

from commands import execute
from tests.harness import Harness

ISSUE = "https://github.com/o/r/issues/29"


def comment(n: int, minute: int, body: str) -> dict[str, Any]:
    return {
        "id": n,
        "html_url": f"{ISSUE}#issuecomment-{n}",
        "body": body,
        "created_at": f"2026-10-12T10:{minute:02d}:00Z",
    }


def event(role: str, name: str, session: str, text: str) -> str:
    return f"EVENT {role} {name} {session}\n{text}"


class BoardTest(Harness):
    def board(
        self,
        *args: str,
        body: str = "",
        ok: bool = True,
        pane: str | None = None,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        extra = dict(env or {})
        if pane:
            extra["HERDR_PANE_ID"] = pane
        result = execute(
            ["python3", str(self.repo / "agent/teams/board.py"), *args],
            cwd=self.repo,
            env={**self.env, **extra},
            input_text=body,
            timeout=60,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    def bodies(self) -> list[str]:
        return [c["body"] for c in self.comments("29")]

    def test_post_and_read_from_a_launched_pane(self) -> None:
        self.team("start", "29")
        impl = self.pane("team-1-impl")["pane_id"]
        launches = self.bodies()
        url = self.board("post", "29", "QUESTION", pane=impl, body="Which port?\n")
        assert url.stdout.strip() == f"{ISSUE}#issuecomment-3"
        question = "QUESTION implementer team-1-impl session-team-1-impl\nWhich port?"
        assert self.bodies() == [*launches, question]
        assert not self.prompts("dispatcher")  # only BLOCKED wakes the dispatcher
        # A repeat after an uncertain post returns the existing URL, for EVENTs too.
        again = self.board("post", "29", "QUESTION", pane=impl, body="Which port?\n")
        assert again.stdout == url.stdout
        launch = ("post", "29", "EVENT", "--as", "designer", "lead", "s-lead")
        first = self.board(*launch, body="launched codex by hand").stdout
        assert self.board(*launch, body="launched codex by hand").stdout == first
        assert self.bodies()[-1] == "EVENT designer lead s-lead\nlaunched codex by hand"
        # A pane without a record needs --role; too long a body posts with a warning.
        self.update(strays=[{"pane_id": "wL:p1", "name": "lead", "agent": "codex", "cwd": "/"}])
        refused = self.board("post", "29", "PROPOSAL", pane="wL:p1", body="x", ok=False)
        assert "No allocation record names lead; give --role" in refused.stderr
        long = self.board(
            "post",
            "29",
            "CRITIQUE",
            "--role",
            "designer",
            pane="wL:p1",
            body="word " * 801,
        )
        assert "801 words, above 800" in long.stderr
        assert self.bodies()[-1].startswith("CRITIQUE designer lead unknown\nword ")
        count = len(self.bodies())
        for args, body, message in (
            (("ANSWER",), "x", "HERDR_PANE_ID is not set"),
            (("NOTE", "--as", "a", "b", "c"), "x", "must be one of"),
            (("ANSWER", "--as", "a", "b", "c"), "", "empty"),
        ):
            with self.subTest(args=args):
                assert message in self.board("post", "29", *args, body=body, ok=False).stderr
        assert len(self.bodies()) == count
        # read gives the current body with every comment, or only the comments after a
        # checkpoint, without the body.
        self.update(issues={**self.state()["issues"], "29": "Revised brief\n"})
        whole = self.board("read", "29").stdout
        oldest = self.comments("29")[0]
        assert whole.startswith(f"{ISSUE}\nRevised brief\n")
        assert f"--- {oldest['html_url']} {oldest['created_at']}\n{oldest['body']}" in whole
        after = self.board("read", "29", "--after", url.stdout.strip()).stdout
        assert after.startswith(f"{ISSUE}\n\n--- ")
        assert "Revised brief" not in after
        assert "Which port?" not in after
        assert after.count("\n--- ") == count - 3
        assert "comment link" in self.board("read", "29", "--after", ISSUE, ok=False).stderr

    def test_a_worker_blocked_post_wakes_the_dispatcher(self) -> None:
        self.team("start", "29")
        impl = self.pane("team-1-impl")["pane_id"]
        posted = self.board("post", "29", "BLOCKED", pane=impl, body="mix deps.get fails\n")
        url = self.comments("29")[-1]["html_url"]
        assert posted.stdout.startswith(f"{url}\n")
        assert self.prompts("dispatcher") == [f"{url} blocked"]

    def test_a_failed_blocked_notice_exits_nonzero_and_its_rerun_reuses_the_comment(
        self,
    ) -> None:
        self.team("start", "29")
        impl = self.pane("team-1-impl")["pane_id"]
        self.update(dispatcher_down=True)
        failed = self.board("post", "29", "BLOCKED", pane=impl, body="db down\n", ok=False)
        url = self.comments("29")[-1]["html_url"]
        assert failed.stdout.strip() == url
        assert "agent_not_found: dispatcher" in failed.stderr
        assert "rerun this command to retry only the notification" in failed.stderr
        count = len(self.bodies())
        self.update(dispatcher_down=False)
        again = self.board("post", "29", "BLOCKED", pane=impl, body="db down\n")
        assert again.stdout.startswith(f"{url}\n")
        assert len(self.bodies()) == count
        # The failed attempt and the rerun's delivered one.
        assert self.prompts("dispatcher") == [f"{url} blocked"] * 2

    def test_usage_counts_each_launched_session_from_its_own_logs(self) -> None:
        self.update(
            comments={
                "29": [
                    comment(
                        1, 0, event("implementer", "team-1-impl", "s-impl-a", "launched codex")
                    ),
                    comment(2, 1, event("tester", "team-1-tester", "s-t", "launched claude")),
                    # A relaunch is a new session under the old name; a hand launch counts too.
                    comment(
                        3, 2, event("implementer", "team-1-impl", "s-impl-b", "launched codex")
                    ),
                    comment(4, 3, event("designer", "lead", "s-lead", "launched codex by hand")),
                    comment(5, 4, event("dispatcher", "dispatcher", "s-d", "board changed")),
                    comment(6, 5, "R1 PROPOSAL designer lead s-lead\nnot a launch"),
                ]
            }
        )
        # Session logs as the clients write them, under a home of their own.
        home = self.root / "home"
        claude = home / ".claude/projects/-repo"
        (claude / "s-t/subagents").mkdir(parents=True)
        usage = {
            "input_tokens": 10,
            "output_tokens": 5,
            "cache_read_input_tokens": 100,
            "cache_creation_input_tokens": 20,
        }
        advisor = {"type": "advisor_message", "model": "fixture-advisor", "input_tokens": 47}
        iterations = [{"type": "message", **usage}, {**advisor, "output_tokens": 6}]
        message = {
            "id": "m1",
            "model": "fixture-test",
            "usage": {**usage, "iterations": iterations},
        }
        line = json.dumps({"type": "assistant", "message": message})
        # A message appears once per content block and is counted once, with its advisor call.
        (claude / "s-t.jsonl").write_text(f"{line}\n{line}\nnot json\n")
        (claude / "s-t/subagents/agent-1.jsonl").write_text(
            json.dumps(
                {
                    "type": "assistant",
                    "message": {"id": "m3", "model": "claude-haiku", "usage": usage},
                }
            )
            + "\n"
        )
        codex = home / ".codex/sessions/2026/10/12"
        codex.mkdir(parents=True)
        record = {
            "input_tokens": 300,
            "cached_input_tokens": 200,
            "cache_write_input_tokens": 7,
            "output_tokens": 40,
        }
        (codex / "rollout-2026-10-12T10-00-00-s-impl-a.jsonl").write_text(
            "\n".join(
                json.dumps(e)
                for e in (
                    {"type": "turn_context", "payload": {"model": "fixture-impl"}},
                    {
                        "type": "token_usage_record",
                        "payload": {"response_id": "r1", "usage": record},
                    },
                    {
                        "type": "token_usage_record",
                        "payload": {"response_id": "r1", "usage": record},
                    },
                    {
                        "type": "token_usage_record",
                        "payload": {"response_id": "r2", "usage": record},
                    },
                )
            )
            + "\n"
        )
        rows = self.board("usage", "29", env={"HOME": str(home)}).stdout.splitlines()
        tester = "| team-1-tester | tester | s-t | "
        assert rows[2:] == [
            "| lead | designer | s-lead | no logs found | 0 | 0 | 0 | 0 |",
            "| team-1-impl | implementer | s-impl-a | fixture-impl | 200 | 80 | 400 | 14 |",
            "| team-1-impl | implementer | s-impl-b | no logs found | 0 | 0 | 0 | 0 |",
            tester + "claude-haiku | 10 | 5 | 100 | 20 |",
            tester + "fixture-advisor | 47 | 6 | 0 | 0 |",
            tester + "fixture-test | 10 | 5 | 100 | 20 |",
        ]

    def test_usage_takes_an_unknown_launch_session_from_the_clients_later_comments(self) -> None:
        tester = "launched codex in /a; allocation g1-sol-tester"
        critic = "launched codex in /b; allocation g1-critic"
        self.update(
            comments={
                # Launch EVENTs go on the brief; a reset's replacement posts the same body,
                # which is deduplicated, so the brief shows one launch for both clients.
                "29": [
                    comment(1, 1, event("tester", "team-1-sol-tester", "unknown", tester)),
                    comment(2, 2, event("critic", "team-1-critic", "unknown", critic)),
                    comment(3, 3, event("tester", "team-1-sol-tester", "unknown", "stopped")),
                ],
                # The clients post on the PR. An earlier comment under the name is no launch.
                "30": [
                    comment(10, 0, event("tester", "team-1-sol-tester", "s-old", "earlier")),
                    comment(11, 4, event("tester", "team-1-sol-tester", "s-sol", "Done")),
                    comment(12, 5, event("dispatcher", "dispatcher", "s-d", "board changed")),
                    comment(13, 6, "HANDOFF tester team-1-sol-tester s-sol\nReady"),
                    comment(14, 7, event("tester", "team-1-sol-tester", "s-new", "Done again")),
                ],
            }
        )
        codex = self.root / "home/.codex/sessions/2026/10/12"
        codex.mkdir(parents=True)
        usage = {"input_tokens": 30, "cached_input_tokens": 10, "output_tokens": 4}
        (codex / "rollout-2026-10-12T10-00-00-s-sol.jsonl").write_text(
            json.dumps({"type": "turn_context", "payload": {"model": "fixture-sol"}})
            + "\n"
            + json.dumps(
                {"type": "token_usage_record", "payload": {"response_id": "r1", "usage": usage}}
            )
            + "\n"
        )
        home = {"HOME": str(self.root / "home")}
        rows = self.board("usage", "29", "30", env=home).stdout.splitlines()
        assert rows[2:] == [
            "| team-1-critic | critic | unknown | no logs found | 0 | 0 | 0 | 0 |",
            "| team-1-sol-tester | tester | s-new | no logs found | 0 | 0 | 0 | 0 |",
            "| team-1-sol-tester | tester | s-sol | fixture-sol | 20 | 4 | 10 | 0 |",
        ]
        # The brief alone has no client comments: the tester stays unknown.
        rows = self.board("usage", "29", env=home).stdout.splitlines()
        assert "| team-1-sol-tester | tester | unknown | no logs found | 0 | 0 | 0 | 0 |" in rows


if __name__ == "__main__":
    unittest.main()
