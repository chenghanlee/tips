#!/usr/bin/env python3
"""Post and read comments on spec and brief issues, and report token counts.

Usage:
  agent/teams/board.py post <issue> <TYPE> [--role ROLE] [--as ROLE NAME SESSION]
                            (body on stdin)
  agent/teams/board.py read <issue> [--after <comment URL>]
  agent/teams/board.py usage <issue>...

post prints the comment URL. If the same comment already exists, it returns that URL
instead of posting again. When you post an EVENT for a new occurrence, use different
comment text. A relaunch already differs because its header has a new session ID.
Header format: `<TYPE> <role> <name> <session>`. The Herdr pane supplies
the name and session; the allocation record supplies the role. Use --role if no record
names you, or --as to post for another agent (for example, a launch or takeover record).
Above 800 words, the command warns; include the reason in the comment.
Create a gist before linking a log:
`gh gist create <file>`.

read prints the current issue body and every comment, or only comments after the given
comment.

usage prints a Markdown table with token counts by model for each session named in a
launch EVENT. team.py posts one EVENT per launch; the dispatcher posts one for a manual
launch. The command reads Claude logs from `~/.claude/projects`, including advisor calls
and subagents, and Codex logs from `~/.codex/sessions`. Input counts show uncached input;
cache reads and writes have separate columns. Counts cover the session's full lifetime,
so use fresh sessions for a trial or compare tables from before and after it.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from collections.abc import Iterator
from pathlib import Path
from typing import cast

import team
from team import (
    HEADER,
    comment_header,
    event_role,
    github_seconds,
    herdr,
    issue_comments,
    object_fields,
    object_list,
    post_comment,
    records,
    repo_args,
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


def post_as(issue: str, kind: str, poster: tuple[str, str, str], text: str) -> str:
    """Post text under the `<TYPE> <role> <name> <session>` header; return the comment URL."""
    header = comment_header(kind, *poster)
    body = text.strip()
    if not body:
        raise RuntimeError("Comment text is empty")
    words = len(body.split())
    if words > WORD_LIMIT:
        print(
            f"{words} words, above {WORD_LIMIT}: state the reason in the comment", file=sys.stderr
        )
    return post_comment(issue, f"{header}\n{body}")


def post(args: argparse.Namespace) -> None:
    print(post_as(args.issue, args.type, identity(args), sys.stdin.read()))


def read_text(issue: str, after: int | None) -> str:
    """The issue URL and body, then every comment, or only comments after comment id `after`."""
    output = run(
        "gh", "issue", "view", issue, *repo_args(), "--json", "url,body", timeout=github_seconds()
    )
    view = json.loads(output)
    comments = issue_comments(issue)
    if after is not None:
        comments = [c for c in comments if int(str(c["id"])) > after]
    parts = [f"{view['url']}\n{view['body']}"]
    for comment in comments:
        parts.append(f"\n--- {comment['html_url']} {comment['created_at']}\n{comment['body']}")
    return "\n".join(parts)


def read(args: argparse.Namespace) -> None:
    after = None
    if args.after:
        match = re.search(r"#issuecomment-(\d+)$", args.after)
        if not match:
            raise RuntimeError("--after takes a comment link (#issuecomment-id)")
        after = int(match.group(1))
    print(read_text(args.issue, after))


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
    """Count tokens by model from session and subagent logs, once per assistant message."""
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
    """Count tokens by model from the session's rollout log, once per response."""
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


def launched_sessions(issues: list[str]) -> list[tuple[str, str, str]]:
    """Return unique (name, role, session) tuples from launch EVENTs, sorted by name."""
    found: set[tuple[str, str, str]] = set()
    for issue in issues:
        for comment in issue_comments(issue):
            lines = str(comment.get("body") or "").splitlines()
            match = HEADER.match(lines[0]) if lines else None
            launched = len(lines) > 1 and lines[1].split()[:1] == ["launched"]
            if match and match["type"] == "EVENT" and launched:
                found.add((match["name"], match["role"], match["session"]))
    return sorted(found)


def usage_table(issues: list[str]) -> str:
    """A Markdown table of token counts by model for each session the issues' launch EVENTs name."""
    columns = ("Agent", "Role", "Session", "Model", *COUNTS)
    rows = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for name, role, session in launched_sessions(issues):
        tokens = claude_tokens(session) or codex_tokens(session) or {"no logs found": [0, 0, 0, 0]}
        for model, counts in sorted(tokens.items()):
            rows.append("| " + " | ".join([name, role, session, model, *map(str, counts)]) + " |")
    return "\n".join(rows)


def usage(args: argparse.Namespace) -> None:
    print(usage_table(args.issues))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Post and read issue comments; report session token counts."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    poster = commands.add_parser("post")
    poster.add_argument("issue")
    poster.add_argument("type")
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
