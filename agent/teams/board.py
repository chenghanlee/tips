#!/usr/bin/env python3
"""Post and read comments on spec and brief issues, and report token counts.

Usage:
  agent/teams/board.py post <issue> <TYPE> [--role ROLE] [--as ROLE NAME SESSION]
                            (body on stdin)
  agent/teams/board.py read <issue> [--after <comment URL>]
  agent/teams/board.py usage <issue>...

post prints the comment URL. If the same comment already exists, it returns that URL
instead of posting again. A worker's BLOCKED post then replaces the issue's `turn:` label
with `turn:dispatcher` and sends the dispatcher `<comment URL> blocked`, with any label
error. If either fails, the command exits non-zero; a rerun retries both, not the post.
When you post an EVENT for a new occurrence, use different comment text. A relaunch
already differs because its header has a new session ID.
Header format: `<TYPE> <role> <name> <session>`. The Herdr pane supplies
the name and session; the allocation record supplies the role. Use --role if no record
names you, or --as to post for another agent (for example, a launch or takeover record).
Above 800 words, the command warns; include the reason in the comment.
Create a gist before linking a log:
`gh gist create <file>`.

read prints the issue's labels and current body and every comment, or the labels and only
the comments after the given comment.

usage prints a Markdown table with token counts by model for each client named in a
launch EVENT. team.py posts one EVENT per launch; the dispatcher posts one for a manual
launch. A Codex client's row sums every session started in the allocation its EVENT
names. The command reads Claude logs from `~/.claude/projects`, including advisor calls
and subagents, and Codex logs from `~/.codex/sessions`. Input counts show uncached input;
cache reads and writes have separate columns. Counts cover the session's full lifetime,
so use fresh sessions for a trial or compare tables from before and after it.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from collections.abc import Iterator
from pathlib import Path
from typing import cast

import config as conf
from commands import object_fields, object_list
from github import (
    comment_header,
    deadline_from_now,
    event_role,
    github,
    header_session,
    issue_comments,
    parse_comment,
    post_comment,
    repo_args,
)
from herdr import herdr, session_id
from team import records, replace_labels

WORD_LIMIT = 800
CODEX_LAUNCH = re.compile(r"launched codex in (?P<root>[^;]+);")
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
    poster = identity(args)
    url = post_as(args.issue, args.type, poster, sys.stdin.read())
    print(url, flush=True)
    if args.type != "BLOCKED":
        return
    # The blocker hands the turn to the dispatcher; the phase stays. A failed label write
    # never withholds the notice: the dispatcher is the one who repairs it.
    label_error = ""
    try:
        replace_labels(args.issue, ("turn:",), ["turn:dispatcher"])
    except (RuntimeError, OSError, ValueError) as error:
        label_error = f"label turn:dispatcher not set: {error}"
    notice = f"{url} blocked" + (f"; {label_error}" if label_error else "")
    try:
        herdr("agent", "prompt", "dispatcher", notice)
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"posted {url}; notifying the dispatcher failed: {error}. "
            + (f"Also {label_error}. " if label_error else "")
            + "The post reuses an identical comment, so rerun this command to retry the "
            "label and the notification"
        ) from error
    print("Notified dispatcher")
    if label_error:
        raise RuntimeError(f"posted {url} and notified the dispatcher, but {label_error}")


def read_text(issue: str, after: int | None) -> str:
    """The issue URL, labels and body, then every comment; with `after`, the URL, labels and
    only the comments after that comment id, so new comments stay reachable on a long
    issue."""
    deadline = deadline_from_now()
    command = ["gh", "issue", "view", issue, *repo_args(), "--json", "url,labels,body"]
    view = json.loads(github(command, deadline, f"#{issue}"))
    comments = issue_comments(issue, deadline)
    if after is not None:
        comments = [c for c in comments if int(str(c["id"])) > after]
    names = ", ".join(str(label["name"]) for label in view["labels"]) or "none"
    heading = f"{view['url']}\nLabels: {names}"
    parts = [heading if after is not None else f"{heading}\n{view['body']}"]
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


def codex_sessions_by_cwd() -> dict[str, set[str]]:
    """Each working directory's Codex session ids, from the `session_meta` line that opens
    every rollout log. A file without one is skipped and named on stderr."""
    found: dict[str, set[str]] = defaultdict(set)
    for file in (Path.home() / ".codex/sessions").glob("*/*/*/rollout-*.jsonl"):
        try:
            with file.open() as lines:
                entry = object_fields(json.loads(lines.readline()), str(file))
            meta = entry if entry.get("type") == "session_meta" else {}
            payload = object_fields(meta["payload"], f"{file} payload")
            found[str(payload["cwd"])].add(str(payload["id"]))
        except (ValueError, KeyError):
            print(f"board: {file} has no session_meta first line; not counted", file=sys.stderr)
    return found


def launched_sessions(issues: list[str]) -> list[tuple[str, str, list[str]]]:
    """Return (name, role, sessions) for each client a launch EVENT names, sorted by name.

    Codex reports its session to Herdr only after startup, so its launch EVENT may say
    "unknown" (#451). A Codex launch EVENT names the allocation root the client starts in,
    and Codex records that directory as the `cwd` of each rollout: every session started
    there counts in one row, a replacement after a reset included. With none, the EVENT's
    session stays.
    """
    clients: dict[tuple[str, str, str], set[str]] = defaultdict(set)
    roots: dict[tuple[str, str, str], str] = {}
    for comment in (c for issue in issues for c in issue_comments(issue)):
        parsed = parse_comment(comment)
        if not parsed:
            continue
        match, lines = parsed
        if match["type"] != "EVENT" or lines[:1] == [] or lines[0].split()[:1] != ["launched"]:
            continue
        codex = CODEX_LAUNCH.match(lines[0])
        key = (match["name"], match["role"], codex["root"] if codex else match["session"])
        clients[key].add(match["session"])
        if codex:
            roots[key] = codex["root"]
    by_cwd = codex_sessions_by_cwd() if roots else {}
    unknown = header_session("")
    rows: list[tuple[str, str, list[str]]] = []
    for key, sessions in sorted(clients.items()):
        started: set[str] = by_cwd.get(roots[key], set()) if key in roots else set()
        found = (sessions | started) - {unknown}
        rows.append((key[0], key[1], sorted(found or sessions)))
    return rows


def usage_table(issues: list[str]) -> str:
    """A Markdown table of token counts by model for each client the issues' launch EVENTs name."""
    columns = ("Agent", "Role", "Session", "Model", *COUNTS)
    rows = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    for name, role, sessions in launched_sessions(issues):
        tokens: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
        for session in sessions:
            for model, counts in (claude_tokens(session) or codex_tokens(session)).items():
                tokens[model] = [a + b for a, b in zip(tokens[model], counts, strict=True)]
        listed = ", ".join(sessions)
        for model, counts in sorted((tokens or {"no logs found": [0, 0, 0, 0]}).items()):
            rows.append("| " + " | ".join([name, role, listed, model, *map(str, counts)]) + " |")
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
    conf.configure()
    args.handler(args)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"board: {error}", file=sys.stderr)
        sys.exit(1)
