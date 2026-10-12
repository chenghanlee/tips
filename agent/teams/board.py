#!/usr/bin/env python3
"""The swarm board: typed comments on the spec and brief issues of the swarm project.

Usage:
  agent/teams/board.py post <issue> <TYPE> [--round N] [--role ROLE] [--as ROLE NAME SESSION]
                            (body on stdin)
  agent/teams/board.py read <issue> [--after <comment URL>]
  agent/teams/board.py usage <issue>...

post prints the comment URL. An identical round comment already on the issue is reused,
so a repeat after an uncertain post never doubles it; EVENTs are posted every time,
because two handoffs of one head read the same. The header line is
`R<round> <TYPE> <role> <name> <session>`; EVENT has no round. Name and session come
from the calling Herdr pane and the role from the allocation records; give --role when
no record names you, or --as to post for another agent (a launch or takeover record).
Above 800 words the command warns; state the reason in the comment. Link logs as gists
made beforehand with `gh gist create <file>`.

read prints the current issue body, then every comment, or only those after the given
comment.

usage prints one Markdown table for the given spec and brief issues: per agent and
session, elapsed time from its launch EVENT to its stop EVENT (or now), the time it
held a pair checkout (from launch and handoff EVENTs; blank for agents that never held
one), and tokens per model from its own session logs: `~/.claude/projects` JSONL for
Claude, with its advisor calls and subagent logs, and `~/.codex/sessions` for Codex.
Input counts uncached input only; cache read and cache write are separate columns.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import TypedDict, cast

import team
from team import (
    HEADER,
    comment_header,
    event_role,
    herdr,
    issue_comments,
    object_fields,
    object_list,
    post_comment,
    records,
    run,
    session_id,
)

WORD_LIMIT = 800
COUNTS = ("Input", "Output", "Cache read", "Cache write")


def identity(args: argparse.Namespace) -> tuple[str, str, str]:
    """(role, name, session) of the poster."""
    if args.as_:
        return args.as_[0], args.as_[1], args.as_[2]
    pane = os.environ.get("HERDR_PANE_ID")
    if not pane:
        raise RuntimeError("HERDR_PANE_ID is not set; post from your own Herdr pane or use --as")
    agent = herdr("agent", "get", pane)["agent"]
    name = str(agent.get("name") or "")
    if not name:
        raise RuntimeError(f"Pane {pane} runs no named agent; use --as")
    role = args.role or ("dispatcher" if name == "dispatcher" else "")
    if not role:
        for record in records().values():
            for allocation in record["agents"].values():
                if allocation["name"] == name:
                    role = event_role(allocation)
    if not role:
        raise RuntimeError(f"No allocation record names {name}; give --role")
    return role, name, session_id(agent)


def post(args: argparse.Namespace) -> None:
    role, name, session = identity(args)
    header = comment_header(args.type, role, name, session, args.round)
    body = sys.stdin.read().strip()
    if not body:
        raise RuntimeError("The comment body comes on stdin and is empty")
    words = len(body.split())
    if words > WORD_LIMIT:
        print(
            f"{words} words, above {WORD_LIMIT}: state the reason in the comment", file=sys.stderr
        )
    print(post_comment(args.issue, f"{header}\n{body}"))


def read(args: argparse.Namespace) -> None:
    view = json.loads(run("gh", "issue", "view", args.issue, "--json", "url,body"))
    comments = issue_comments(args.issue)
    if args.after:
        match = re.search(r"#issuecomment-(\d+)$", args.after)
        if not match:
            raise RuntimeError("--after takes a comment link (#issuecomment-id)")
        comments = [c for c in comments if int(str(c["id"])) > int(match.group(1))]
    print(f"{view['url']}\n{view['body']}")
    for comment in comments:
        print(f"\n--- {comment['html_url']} {comment['created_at']}\n{comment['body']}")


def when(text: object) -> datetime:
    return datetime.fromisoformat(str(text))


def log_entries(files: list[Path]) -> Iterator[dict[str, object]]:
    for file in files:
        for line in file.read_text().splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                yield cast(dict[str, object], entry)


def count(usage: dict[str, object], key: str) -> int:
    value = usage.get(key)
    return value if isinstance(value, int) else 0


def claude_tokens(session: str) -> dict[str, list[int]]:
    """Tokens per model from the session's own log and its subagents', one count per message."""
    home = Path.home() / ".claude/projects"
    files = list(home.glob(f"*/{session}.jsonl"))
    files += list(home.glob(f"*/{session}/subagents/*.jsonl"))
    messages: dict[str, tuple[str, dict[str, object]]] = {}
    for entry in log_entries(files):
        if entry.get("type") != "assistant" or not isinstance(entry.get("message"), dict):
            continue
        message = object_fields(entry["message"], "assistant message")
        if isinstance(message.get("usage"), dict):
            usage = object_fields(message["usage"], "usage")
            messages[str(message.get("id"))] = (str(message.get("model")), usage)
    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
    keys = (
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    )
    for model, usage in messages.values():
        for i, key in enumerate(keys):
            totals[model][i] += count(usage, key)
        # The outer totals exclude advisor calls; each is its own iteration with its model.
        iterations = usage.get("iterations")
        calls = object_list(iterations, "iterations") if iterations is not None else []
        for call in calls:
            if call.get("type") == "advisor_message":
                for i, key in enumerate(keys):
                    totals[str(call.get("model"))][i] += count(call, key)
    return totals


def codex_tokens(session: str) -> dict[str, list[int]]:
    """Tokens per model from the session's rollout log, one count per response."""
    files = list((Path.home() / ".codex/sessions").glob(f"*/*/*/rollout-*-{session}.jsonl"))
    model = "codex"
    responses: dict[str, tuple[str, dict[str, object]]] = {}
    for entry in log_entries(files):
        if not isinstance(entry.get("payload"), dict):
            continue
        payload = object_fields(entry["payload"], "payload")
        if entry.get("type") == "turn_context" and payload.get("model"):
            model = str(payload["model"])
        elif entry.get("type") == "token_usage_record" and isinstance(payload.get("usage"), dict):
            usage = object_fields(payload["usage"], "usage")
            responses[str(payload.get("response_id"))] = (model, usage)
    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
    for model, usage in responses.values():
        cached = count(usage, "cached_input_tokens")
        totals[model][0] += count(usage, "input_tokens") - cached
        totals[model][1] += count(usage, "output_tokens")
        totals[model][2] += cached
        totals[model][3] += count(usage, "cache_write_input_tokens")
    return totals


def duration(seconds: float) -> str:
    return f"{int(seconds // 3600)}h{int(seconds % 3600 // 60):02d}m"


class Agent(TypedDict):
    role: str
    launch: datetime | None
    stop: datetime | None


Event = tuple[
    datetime, str, str, str, str
]  # time, issue, "launched"/"handoff"/"stopped", name, session


def board_events(issues: list[str]) -> tuple[dict[tuple[str, str], Agent], list[Event]]:
    """Every attributed poster, and the launch, handoff and stop EVENTs in time order.

    A handoff names its recipient by live name; the recipient's session is resolved to
    its latest launch on that issue, since a relaunch is a new session under the old name.
    """
    agents: dict[tuple[str, str], Agent] = {}
    events: list[Event] = []
    for issue in issues:
        for comment in issue_comments(issue):
            lines = str(comment.get("body") or "").splitlines()
            match = HEADER.match(lines[0]) if lines else None
            if not match:
                continue
            at = when(comment["created_at"])
            agent = agents.setdefault(
                (match["name"], match["session"]), Agent(role=match["role"], launch=None, stop=None)
            )
            words = lines[1].split() if match["type"] == "EVENT" and len(lines) > 1 else []
            if words[:1] == ["launched"]:
                agent["launch"] = min(agent["launch"] or at, at)
                events.append((at, issue, "launched", match["name"], match["session"]))
            elif words[:1] == ["stopped"]:
                agent["stop"] = at
                events.append((at, issue, "stopped", match["name"], match["session"]))
            elif words[:1] == ["handoff"]:
                events.append((at, issue, "handoff", words[-1], ""))
    return agents, sorted(events, key=lambda e: e[0])


def working_time(
    agents: dict[tuple[str, str], Agent], events: list[Event], now: datetime
) -> dict[tuple[str, str], float]:
    """Seconds each session held a pair checkout: from the EVENT giving it the turn to the next."""
    working: dict[tuple[str, str], float] = {}
    holder: dict[str, tuple[tuple[str, str], datetime]] = {}
    current: dict[tuple[str, str], str] = {}  # (issue, name) -> latest launched session

    def release(issue: str, at: datetime) -> None:
        held = holder.pop(issue, None)
        if held:
            working[held[0]] = working.get(held[0], 0) + (at - held[1]).total_seconds()

    for at, issue, kind, name, session in events:
        if kind == "launched":
            current[issue, name] = session
            if agents[name, session]["role"] == "implementer":
                release(issue, at)
                holder[issue] = ((name, session), at)
        elif kind == "handoff":
            release(issue, at)
            holder[issue] = ((name, current.get((issue, name), "")), at)
        elif holder.get(issue, ((None, None), None))[0] == (name, session):
            release(issue, at)
    for key, since in holder.values():
        working[key] = working.get(key, 0) + (now - since).total_seconds()
    return working


def usage(args: argparse.Namespace) -> None:
    now = datetime.now(UTC)
    agents, events = board_events(args.issues)
    working = working_time(agents, events, now)
    columns = ("Agent", "Role", "Session", "Elapsed", "Working", "Model", *COUNTS)
    print("| " + " | ".join(columns) + " |")
    print("|" + "---|" * len(columns))
    for (name, session), agent in sorted(agents.items()):
        launch, stop = agent["launch"], agent["stop"]
        elapsed = duration(((stop or now) - launch).total_seconds()) if launch else ""
        if launch and not stop:
            elapsed += " (running)"
        held = duration(working[name, session]) if (name, session) in working else ""
        tokens = claude_tokens(session) or codex_tokens(session) or {"no logs found": [0, 0, 0, 0]}
        for model, counts in sorted(tokens.items()):
            cells = [name, agent["role"], session, elapsed, held, model, *map(str, counts)]
            print("| " + " | ".join(cells) + " |")


def main() -> None:
    parser = argparse.ArgumentParser(description="The swarm board.")
    commands = parser.add_subparsers(dest="command", required=True)
    poster = commands.add_parser("post")
    poster.add_argument("issue")
    poster.add_argument("type")
    poster.add_argument("--round", type=int)
    poster.add_argument("--role")
    poster.add_argument("--as", dest="as_", nargs=3, metavar=("ROLE", "NAME", "SESSION"))
    poster.set_defaults(handler=post)
    reader = commands.add_parser("read")
    reader.add_argument("issue")
    reader.add_argument("--after")
    reader.set_defaults(handler=read)
    meter = commands.add_parser("usage")
    meter.add_argument("issues", nargs="+")
    meter.set_defaults(handler=usage)
    args = parser.parse_args()
    team.configure()
    args.handler(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"board: {error}", file=sys.stderr)
        sys.exit(1)
