"""Requests to the dispatcher, read from the existing GitHub records; no cursor or inbox.

A request is a worker's BLOCKED or DONE board comment on a brief or PR an allocation
record names. A dispatcher action record names the requests it answers: a dispatcher
comment whose last marker line is
`TEAM_ACTION {"v": 1, "sources": [<comment ids>], "state": "done" | "pending" | "failed"}`.
Every adapter action that answers a request takes the source ids and writes that record.
The latest record naming a request decides: none or failed means it needs action; pending
means the action was attempted or delivered and its outcome is not known; done means
handled. State comes from the records alone, so it survives restarts and compaction. An
unrelated dispatcher comment handles nothing, and a request posted after an action stays
open. After a crash between an action and its record, the request is returned again; the
launch and prompt guards refuse a blind repeat. Every agent posts as the same GitHub
account, so a header is attribution, not authentication. Each call bounds its GitHub
requests, reports how many it made, and refuses to decide on an incomplete history.
"""

import json
import re
import subprocess
import time
from dataclasses import dataclass, field
from typing import cast

import team

REQUEST_TYPES = ("BLOCKED", "DONE")
MARKER = "TEAM_ACTION "
STATES = ("done", "pending", "failed")
PAGE_SIZE = 100
# At most 10 pages of 100 comments per issue; a longer history is incomplete.
PAGES = 10
# Upper bound on GitHub requests in one call, whatever the wait.
REQUEST_BUDGET = 120
POLL_SECONDS = 30
BODY_CHARS = 600


class IncompleteError(RuntimeError):
    """A comment history longer than the reader may fetch; no decision is made on it."""


class BudgetError(RuntimeError):
    """The call used its GitHub request budget."""


@dataclass
class Budget:
    limit: int
    used: int = 0

    def spend(self) -> None:
        if self.used >= self.limit:
            raise BudgetError(f"request budget of {self.limit} GitHub requests used")
        self.used += 1


@dataclass
class Scan:
    requests: list[dict[str, object]] = field(default_factory=list[dict[str, object]])
    awaiting_outcome: list[dict[str, object]] = field(default_factory=list[dict[str, object]])


def comments(issue: int, budget: Budget) -> list[dict[str, object]]:
    """Every comment of the issue, oldest first, one counted request per page."""
    found: list[dict[str, object]] = []
    for page in range(1, PAGES + 1):
        budget.spend()
        path = f"repos/{team.repository()}/issues/{issue}/comments"
        query = f"{path}?per_page={PAGE_SIZE}&page={page}"
        batch = team.object_list(
            json.loads(team.run("gh", "api", query, timeout=team.github_seconds())), "comments"
        )
        found += batch
        if len(batch) < PAGE_SIZE:
            return found
    raise IncompleteError(f"#{issue} has more than {PAGES * PAGE_SIZE} comments")


def header(comment: dict[str, object]) -> re.Match[str] | None:
    lines = str(comment.get("body") or "").splitlines()
    return team.HEADER.match(lines[0]) if lines else None


def is_request(comment: dict[str, object]) -> bool:
    match = header(comment)
    return bool(match and match["type"] in REQUEST_TYPES and match["role"] != "dispatcher")


def action(comment: dict[str, object]) -> tuple[list[int], str] | None:
    """The source ids and state a dispatcher action record names, or None."""
    match = header(comment)
    if not match or match["role"] != "dispatcher":
        return None
    for line in reversed(str(comment.get("body") or "").splitlines()):
        if line.startswith(MARKER):
            try:
                record = team.object_fields(json.loads(line[len(MARKER) :]), "action record")
            except ValueError:
                return None
            sources, state = record.get("sources"), record.get("state")
            if isinstance(sources, list) and state in STATES:
                ids = [s for s in cast(list[object], sources) if isinstance(s, int)]
                return ids, str(state)
    return None


def marker(sources: list[int], state: str) -> str:
    return MARKER + json.dumps({"v": 1, "sources": sorted(set(sources)), "state": state})


def item(issue: int, comment: dict[str, object]) -> dict[str, object]:
    match = header(comment)
    body = str(comment.get("body") or "")
    return {
        "comment_id": comment.get("id"),
        "issue": issue,
        "type": match["type"] if match else "",
        "from": match["name"] if match else "",
        "url": comment.get("html_url"),
        "created_at": comment.get("created_at"),
        "body": body[:BODY_CHARS],
    }


def scan(issues: list[int], budget: Budget) -> Scan:
    result = Scan()
    for issue in issues:
        history = comments(issue, budget)
        named: dict[int, str] = {}
        for comment in history:
            recorded = action(comment)
            if recorded:
                for source in recorded[0]:
                    named[source] = recorded[1]
        for comment in history:
            if is_request(comment):
                state = named.get(int(str(comment.get("id"))))
                if state is None:
                    result.requests.append(item(issue, comment))
                elif state == "failed":
                    result.requests.append({**item(issue, comment), "last_action": state})
                elif state == "pending":
                    result.awaiting_outcome.append(item(issue, comment))
    return result


def watched() -> list[int]:
    """Every brief and reviewed PR an allocation record names."""
    # PR4 integration point (#441): add the spec issues of design allocations.
    numbers: set[int] = set()
    for record in team.records().values():
        numbers.add(int(record["brief"]))
        for allocation in record["agents"].values():
            if pr := allocation.get("pr"):
                numbers.add(int(pr))
    return sorted(numbers)


def wait(seconds: float, poll: float = POLL_SECONDS) -> dict[str, object]:
    """Return open requests at once, or wait up to `seconds` for one to arrive.

    The first read happens on entry, so a request posted between two calls is seen.
    Results: requests, timeout, idle (nothing to watch), unavailable or incomplete.
    """
    budget = Budget(REQUEST_BUDGET)
    deadline = time.monotonic() + seconds
    report: dict[str, object] = {}

    def result(name: str, **details: object) -> dict[str, object]:
        return {"result": name, **report, **details, "github_requests": budget.used}

    try:
        issues = watched()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        return result("unavailable", detail=f"allocation records: {error}")
    report["watched"] = issues
    if not issues:
        return result("idle")
    while True:
        try:
            found = scan(issues, budget)
        except IncompleteError as error:
            return result("incomplete", detail=str(error))
        except BudgetError as error:
            return result("timeout", detail=str(error))
        except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            return result("unavailable", detail=str(error))
        report["awaiting_outcome"] = found.awaiting_outcome
        if found.requests:
            return result("requests", requests=found.requests)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return result("timeout")
        time.sleep(min(poll, remaining))


def source_issues(sources: list[int]) -> dict[int, list[int]]:
    """Group request comment ids by issue; refuse an id that is not a worker request."""
    grouped: dict[int, list[int]] = {}
    for source in sorted(set(sources)):
        path = f"repos/{team.repository()}/issues/comments/{source}"
        comment = team.object_fields(
            json.loads(team.run("gh", "api", path, timeout=team.github_seconds())), "comment"
        )
        if not is_request(comment):
            raise RuntimeError(f"Comment {source} is not a worker BLOCKED or DONE request")
        issue = re.search(r"/issues/(\d+)$", str(comment.get("issue_url") or ""))
        if not issue:
            raise RuntimeError(f"Comment {source} names no issue")
        grouped.setdefault(int(issue.group(1)), []).append(source)
    return grouped
