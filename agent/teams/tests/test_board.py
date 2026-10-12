"""The board script: attributed posts, reading after a checkpoint, and the usage table."""

import json
import unittest

from team import execute
from tests.test_team import Harness

ISSUE = "https://github.com/o/r/issues/29"


class BoardTest(Harness):
    def board(
        self,
        *args: str,
        body: str = "",
        ok: bool = True,
        pane: str | None = None,
        env: dict[str, str] | None = None,
    ):
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

    def test_post_attributes_the_calling_pane_and_never_doubles_a_comment(self) -> None:
        self.team("start", "29")
        impl = self.pane("team-1-impl")["pane_id"]
        posted = len(self.comments("29"))
        url = self.board(
            "post", "29", "QUESTION", "--round", "1", pane=impl, body="Which port?\n"
        ).stdout
        assert url.strip() == f"{ISSUE}#issuecomment-{posted + 1}"
        assert self.comments("29")[-1]["body"] == (
            "R1 QUESTION implementer team-1-impl session-team-1-impl\nWhich port?"
        )
        # The same comment again is not posted twice: the existing URL comes back.
        again = self.board(
            "post", "29", "QUESTION", "--round", "1", pane=impl, body="Which port?\n"
        )
        assert again.stdout == url
        assert len(self.comments("29")) == posted + 1
        # Attachments become gists; Waiting on is written to the project item.
        (self.repo / "tmp").mkdir(exist_ok=True)
        (self.repo / "tmp/run.log").write_text("log\n")
        self.update(items=["29"])
        attach = ("--attach", "tmp/run.log", "--waiting", "tester,user")
        self.board("post", "29", "FINDING", "--round", "2", *attach, pane=impl, body="See the log.")
        assert self.comments("29")[-1]["body"].endswith(
            "See the log.\n\nAttachments: https://gist.github.com/o/run.log"
        )
        edits = [e for e in self.state()["events"] if e[:3] == ["gh", "project", "item-edit"]]
        edit = ["gh", "project", "item-edit", "--project-id", "PROJECT", "--id", "I29"]
        assert edits == [[*edit, "--field-id", "F2", "--text", "tester, user"]]
        # Long comments post with a warning.
        long = self.board("post", "29", "CRITIQUE", "--round", "2", pane=impl, body="word " * 801)
        assert "801 words, above 800" in long.stderr
        # The dispatcher and an agent without a record post as themselves.
        state = self.state()
        state["strays"] = [
            {"pane_id": "wD:p1", "name": "dispatcher", "agent": "claude", "cwd": str(self.repo),
             "agent_session": {"value": "session-dispatcher"}},
            {"pane_id": "wL:p1", "name": "lead", "agent": "codex", "cwd": str(self.repo)},
        ]  # fmt: skip
        self.save(state)
        self.board("post", "29", "EVENT", pane="wD:p1", body="took over for team-1-impl")
        assert self.comments("29")[-1]["body"].startswith(
            "EVENT dispatcher dispatcher session-dispatcher\n"
        )
        refused = self.board(
            "post", "29", "PROPOSAL", "--round", "1", pane="wL:p1", body="x", ok=False
        )
        assert "No allocation record names lead; give --role" in refused.stderr
        self.board(
            "post", "29", "PROPOSAL", "--round", "1", "--role", "designer", pane="wL:p1", body="x"
        )
        assert self.comments("29")[-1]["body"].startswith("R1 PROPOSAL designer lead unknown\n")
        self.board(
            "post",
            "29",
            "EVENT",
            "--as",
            "designer",
            "lead",
            "s-lead",
            body="launched codex by hand",
        )
        assert (
            self.comments("29")[-1]["body"] == "EVENT designer lead s-lead\nlaunched codex by hand"
        )
        # Refusals before any post: no pane, wrong round use, unknown type, empty body.
        count = len(self.comments("29"))
        for args, body, message in (
            (("post", "29", "ANSWER", "--round", "1"), "x", "HERDR_PANE_ID is not set"),
            (("post", "29", "EVENT", "--round", "1", "--as", "a", "b", "c"), "x", "EVENT has none"),
            (("post", "29", "ANSWER", "--as", "a", "b", "c"), "x", "needs a round"),
            (("post", "29", "NOTE", "--round", "1", "--as", "a", "b", "c"), "x", "must be one of"),
            (("post", "29", "ANSWER", "--round", "1", "--as", "a", "b", "c"), "", "empty"),
        ):
            with self.subTest(args=args):
                assert message in self.board(*args, body=body, ok=False).stderr
        assert len(self.comments("29")) == count

    def test_read_prints_the_body_then_the_comments_after_a_checkpoint(self) -> None:
        self.team("start", "29")
        first, second = self.comments("29")
        whole = self.board("read", "29").stdout
        assert whole.startswith(f"{ISSUE}\nImplementer: impl\nRequired reviews: tester, critic\n")
        assert f"--- {first['html_url']} {first['created_at']}\n{first['body']}" in whole
        after = self.board("read", "29", "--after", first["html_url"]).stdout
        assert "Implementer:" not in after
        assert first["body"] not in after
        assert after.strip() == f"--- {second['html_url']} {second['created_at']}\n{second['body']}"
        assert "comment link" in self.board("read", "29", "--after", ISSUE, ok=False).stderr

    def test_usage_joins_board_events_with_the_session_logs(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        impl, tester = self.pane("team-1-impl")["pane_id"], self.pane("team-1-tester")["pane_id"]
        self.push(wt)
        self.team("turn", "7", "tester", cwd=wt, pane=impl)
        self.team("turn", "7", "impl", cwd=wt, pane=tester)
        self.git("merge", "-q", "--ff-only", "task/29")
        self.clients_exit(1)
        self.team("stop", "29")
        # Session logs as the clients write them, under a home of their own.
        home = self.root / "home"
        claude = home / ".claude/projects/-repo"
        (claude / "session-team-1-tester/subagents").mkdir(parents=True)
        usage = {
            "input_tokens": 10,
            "output_tokens": 5,
            "cache_read_input_tokens": 100,
            "cache_creation_input_tokens": 20,
        }
        line = json.dumps(
            {"type": "assistant", "message": {"id": "m1", "model": "fixture-test", "usage": usage}}
        )
        other = json.dumps(
            {
                "type": "assistant",
                "message": {"id": "m2", "model": "fixture-advisor", "usage": usage},
            }
        )
        # A message appears once per content block; it is counted once.
        (claude / "session-team-1-tester.jsonl").write_text(f"{line}\n{line}\n{other}\nnot json\n")
        (claude / "session-team-1-tester/subagents/agent-1.jsonl").write_text(
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
        (codex / "rollout-2026-10-12T10-00-00-session-team-1-impl.jsonl").write_text(
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
        table = self.board("usage", "29", env={"HOME": str(home)}).stdout.splitlines()
        # Comments are one minute apart: impl launched at :01, tester at :02, handoff to the
        # tester at :03, back at :04, stops at :05 (impl) and :06 (tester).
        tester = "| team-1-tester | tester | session-team-1-tester | 0h04m | 0h01m | "
        assert table[2:] == [
            "| team-1-impl | implementer | session-team-1-impl | 0h04m | 0h03m | fixture-impl "
            "| 200 | 80 | 400 | 14 |",
            tester + "claude-haiku | 10 | 5 | 100 | 20 |",
            tester + "fixture-advisor | 10 | 5 | 100 | 20 |",
            tester + "fixture-test | 10 | 5 | 100 | 20 |",
        ]
        # An agent without logs or a stop is still listed, as running.
        self.board(
            "post",
            "29",
            "EVENT",
            "--as",
            "designer",
            "lead",
            "s-lead",
            body="launched codex by hand",
        )
        rows = self.board("usage", "29", env={"HOME": str(home)}).stdout.splitlines()
        assert any(
            r.startswith("| lead | designer | s-lead | ")
            and "(running) |  | no logs found | 0 | 0 | 0 | 0 |" in r
            for r in rows
        )


if __name__ == "__main__":
    unittest.main()
