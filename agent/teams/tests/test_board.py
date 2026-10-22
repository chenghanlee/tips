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
        launch = ("post", "29", "EVENT", "--as", "architect", "lead", "s-lead")
        first = self.board(*launch, body="launched codex by hand").stdout
        assert self.board(*launch, body="launched codex by hand").stdout == first
        assert self.bodies()[-1] == "EVENT architect lead s-lead\nlaunched codex by hand"
        # A pane without a record needs --role; too long a body posts with a warning.
        self.update(strays=[{"pane_id": "wL:p1", "name": "lead", "agent": "codex", "cwd": "/"}])
        refused = self.board("post", "29", "PROPOSAL", pane="wL:p1", body="x", ok=False)
        assert "No allocation record names lead; give --role" in refused.stderr
        long = self.board(
            "post",
            "29",
            "CRITIQUE",
            "--role",
            "architect",
            pane="wL:p1",
            body="word " * 801,
        )
        assert "801 words, above 800" in long.stderr
        assert self.bodies()[-1].startswith("CRITIQUE architect lead unknown\nword ")
        count = len(self.bodies())
        for args, body, message in (
            (("ANSWER",), "x", "HERDR_PANE_ID is not set"),
            (("NOTE", "--as", "a", "b", "c"), "x", "must be one of"),
            (("ANSWER", "--as", "a", "b", "c"), "", "empty"),
        ):
            with self.subTest(args=args):
                assert message in self.board("post", "29", *args, body=body, ok=False).stderr
        assert len(self.bodies()) == count
        # read gives the labels and the current body with every comment, or the labels and
        # only the comments after a checkpoint, without the body.
        self.update(issues={**self.state()["issues"], "29": "Revised brief\n"})
        whole = self.board("read", "29").stdout
        oldest = self.comments("29")[0]
        labels = "Labels: phase:implement, turn:impl"
        assert whole.startswith(f"{ISSUE}\n{labels}\nRevised brief\n")
        assert f"--- {oldest['html_url']} {oldest['created_at']}\n{oldest['body']}" in whole
        after = self.board("read", "29", "--after", url.stdout.strip()).stdout
        assert after.startswith(f"{ISSUE}\n{labels}\n\n--- ")
        assert "Revised brief" not in after
        assert "Which port?" not in after
        assert after.count("\n--- ") == count - 3
        assert "comment link" in self.board("read", "29", "--after", ISSUE, ok=False).stderr

    def test_a_worker_blocked_post_hands_the_turn_to_the_dispatcher(self) -> None:
        self.team("start", "29")
        self.update(labels={"29": ["phase:review", "turn:tester"]})
        tester = self.pane("team-1-tester")["pane_id"]
        posted = self.board("post", "29", "BLOCKED", pane=tester, body="mix deps.get fails\n")
        url = self.comments("29")[-1]["html_url"]
        assert posted.stdout.startswith(f"{url}\n")
        assert self.labels("29") == ["phase:review", "turn:dispatcher"]
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
        assert "rerun this command to retry the label and the notification" in failed.stderr
        count = len(self.bodies())
        self.update(dispatcher_down=False)
        again = self.board("post", "29", "BLOCKED", pane=impl, body="db down\n")
        assert again.stdout.startswith(f"{url}\n")
        assert len(self.bodies()) == count
        # The failed attempt and the rerun's delivered one.
        assert self.prompts("dispatcher") == [f"{url} blocked"] * 2

    def test_a_blocked_post_whose_label_write_fails_still_notifies_the_dispatcher(self) -> None:
        self.team("start", "29")
        tester = self.pane("team-1-tester")["pane_id"]
        self.update(label_add_fails=True)
        failed = self.board("post", "29", "BLOCKED", pane=tester, body="no answer\n", ok=False)
        url = self.comments("29")[-1]["html_url"]
        assert self.bodies()[-1].endswith("\nno answer")
        error = (
            "label turn:dispatcher not set: Label update of #29 failed: fixture GitHub refused "
            "the label edit. Its labels: phase:implement, turn:impl"
        )
        assert self.prompts("dispatcher") == [f"{url} blocked; {error}"]
        assert f"posted {url}; {error}" in failed.stderr
        assert self.labels("29") == ["phase:implement", "turn:impl"]

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
                    comment(4, 3, event("architect", "lead", "s-lead", "launched codex by hand")),
                    comment(5, 4, event("dispatcher", "dispatcher", "s-d", "board changed")),
                    comment(6, 5, "R1 PROPOSAL architect lead s-lead\nnot a launch"),
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
            "| lead | architect | s-lead | no logs found | 0 | 0 | 0 | 0 |",
            "| team-1-impl | implementer | s-impl-a | fixture-impl | 200 | 80 | 400 | 14 |",
            "| team-1-impl | implementer | s-impl-b | no logs found | 0 | 0 | 0 | 0 |",
            tester + "claude-haiku | 10 | 5 | 100 | 20 |",
            tester + "fixture-advisor | 47 | 6 | 0 | 0 |",
            tester + "fixture-test | 10 | 5 | 100 | 20 |",
        ]

    def test_usage_finds_a_codex_launchs_sessions_by_its_allocation_root(self) -> None:
        # Codex may launch before Herdr knows its session: the EVENT says unknown.
        tester = "launched codex in /a; allocation g1-sol-tester"
        critic = "launched codex in /b; allocation g1-critic"
        self.update(
            comments={
                "29": [
                    comment(1, 1, event("tester", "team-1-sol-tester", "unknown", tester)),
                    comment(2, 2, event("critic", "team-1-critic", "unknown", critic)),
                ],
            }
        )
        codex = self.root / "home/.codex/sessions/2026/10/12"
        codex.mkdir(parents=True)
        usage = {"input_tokens": 30, "cached_input_tokens": 10, "output_tokens": 4}

        def rollout(session: str, cwd: str, first: str = "") -> None:
            meta = {"type": "session_meta", "payload": {"id": session, "cwd": cwd}}
            lines = [
                first or json.dumps(meta),
                json.dumps({"type": "turn_context", "payload": {"model": "fixture-sol"}}),
                json.dumps(
                    {"type": "token_usage_record", "payload": {"response_id": "r1", "usage": usage}}
                ),
            ]
            (codex / f"rollout-2026-10-12T10-00-00-{session}.jsonl").write_text(
                "\n".join(lines) + "\n"
            )

        # The tester's first session and its replacement after a reset both started in /a;
        # a session elsewhere and a log without session_meta are not counted.
        rollout("s-sol", "/a")
        rollout("s-new", "/a")
        rollout("s-other", "/a/project")
        rollout("s-bad", "/a", first="not json")
        result = self.board("usage", "29", env={"HOME": str(self.root / "home")})
        assert result.stdout.splitlines()[2:] == [
            "| team-1-critic | critic | unknown | no logs found | 0 | 0 | 0 | 0 |",
            "| team-1-sol-tester | tester | s-new, s-sol | fixture-sol | 40 | 8 | 20 | 0 |",
        ]
        assert "rollout-2026-10-12T10-00-00-s-bad.jsonl has no session_meta" in result.stderr


if __name__ == "__main__":
    unittest.main()
