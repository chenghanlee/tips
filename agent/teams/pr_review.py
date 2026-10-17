#!/usr/bin/env python3
"""Read a PR's state and record its failures; list reviews and threads; resolve a thread.

Both list and observe read through read_state; list only displays. observe also records
each real failure as a FINDING comment on the PR with a TEAM_FINDING marker line, appends a
resolution naming that comment's ID when later evidence shows the failure gone, and says
whether the PR can merge.
Unavailable evidence records nothing and resolves nothing. The required checks are the
contexts the base branch's effective rules require. GraphQL is used because GitHub's REST
API does not list or resolve review threads.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, cast

import config as conf
import team
from commands import execute, object_fields, object_list, require_type
from config import HEADER, READ_PAGES, READ_SECONDS
from github import (
    add_comment,
    comment_header,
    deadline_from_now,
    github,
    issue_comments,
    poster,
    pull_request,
    repo_args,
)

QUERY = """
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      CONNECTION(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { FIELDS }
      }
    }
  }
}
"""
THREAD_FIELDS = (
    "id isResolved path line originalLine "
    "comments(first: 100) { totalCount nodes { databaseId body pullRequestReview { url } } }"
)
REVIEW_FIELDS = "databaseId state body url commit { oid }"
RESOLVE = """
mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) { thread { isResolved } }
}
"""
UNAVAILABLE = "UNAVAILABLE"
MERGEABILITY = "mergeability"
MARKER = "TEAM_FINDING "
# Version 2: a finding is the comment that opened it; a resolution or supersession names
# that comment's ID, never a check, head and base.
MARKER_VERSION = 2
COMMENT_ID = re.compile(r"#issuecomment-([0-9]+)$")
PASSED = ("pass", "skipping")
FAILED = ("fail", "cancel")


class RefusalError(RuntimeError):
    pass


@dataclass(frozen=True)
class Check:
    identity: str
    name: str
    bucket: str
    link: str


@dataclass(frozen=True)
class Review:
    lgtm: bool
    url: str


@dataclass(frozen=True)
class PrState:
    """One read of a PR. None, or UNAVAILABLE for mergeability, marks evidence GitHub did not
    give; `unavailable` says why. `checks` are the required ones, `optional` the others."""

    number: int
    url: str
    head: str
    base: str
    base_ref: str
    mergeable: str
    checks: tuple[Check, ...] | None
    optional: tuple[Check, ...]
    reviews: dict[str, Review] | None
    review_nodes: tuple[Any, ...]
    threads: tuple[Any, ...] | None
    unavailable: tuple[str, ...]


@dataclass(frozen=True)
class Finding:
    """What failed: the check (or mergeability) at one head and base. One finding can have
    several open events when observers raced; each event is resolved by its own ID."""

    check: str
    head: str
    base: str


@dataclass(frozen=True)
class History:
    """The folded FINDING events: open events by comment ID, and each finding's latest
    event URL."""

    open: dict[int, tuple[Finding, str]]
    latest: dict[Finding, str]


def repository_of(url: str) -> str:
    """The owner/repo of a PR URL."""
    repo = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+", url)
    if not repo:
        raise RefusalError(f"Unexpected PR URL: {url}")
    return repo.group(1)


def connection(repo: str, number: int, name: str, fields: str, deadline: float) -> list[Any]:
    """Return every node in the connection; raise an error if the read is incomplete."""
    owner, repo_name = repo.split("/")
    query = QUERY.replace("CONNECTION", name).replace("FIELDS", fields)
    nodes: list[Any] = []
    after = ""
    for _ in range(READ_PAGES):
        args = ["-f", f"owner={owner}", "-f", f"name={repo_name}", "-F", f"number={number}"]
        if after:
            args += ["-f", f"after={after}"]
        command = ["gh", "api", "graphql", "-f", f"query={query}", *args]
        answer = json.loads(github(command, deadline, f"PR {number} {name}"))
        try:
            page = answer["data"]["repository"]["pullRequest"][name]
            nodes += page["nodes"]
            more, after = page["pageInfo"]["hasNextPage"], page["pageInfo"]["endCursor"]
        except (KeyError, TypeError) as error:
            raise RefusalError(f"GitHub returned an incomplete {name} answer.") from error
        if not more:
            return nodes
        if not after:
            raise RefusalError(f"GitHub returned no cursor for the next {name} page.")
    raise RefusalError(f"PR {number} has over {READ_PAGES * 100} {name}; read incomplete")


def place(thread: Any) -> str:
    return f"{thread['path']}:{thread['line'] or thread['originalLine']}"


def reviewer(body: str) -> str:
    """The role and session line of a review body: its first line, or the one after LGTM."""
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    return next((line for line in lines if line != "LGTM"), "")


def show_thread(thread: Any, owners: dict[str, str]) -> None:
    first, *replies = thread["comments"]["nodes"]
    opened: Any = first["pullRequestReview"] or {}
    owner = owners.get(str(opened.get("url")), "unknown reviewer")
    print(f"\nthread {thread['id']} reply-to {first['databaseId']} {place(thread)} by {owner}")
    print(first["body"].strip())
    for reply in replies:
        print("> " + reply["body"].strip().replace("\n", "\n> "))
    hidden = thread["comments"]["totalCount"] - len(thread["comments"]["nodes"])
    if hidden > 0:
        print(f"> ({hidden} later replies not shown)")


def show(number: int, every_head: bool) -> None:
    """Display recent reviews and every unresolved thread from one read_state."""
    state = read_state(number)
    if state.threads is None:
        raise RefusalError("; ".join(state.unavailable))
    reviews = [
        review
        for review in state.review_nodes
        if review["body"].strip() and review["state"] != "PENDING"
    ]
    # Body feedback has no thread to stay open, so the head before the latest is shown too.
    commits = list(dict.fromkeys(review["commit"]["oid"] for review in reviews))
    recent = commits if every_head else commits[-2:]
    print(f"head {state.head}")
    for review in reviews:
        if review["commit"]["oid"] in recent:
            print(f"\nreview {review['url']} {review['commit']['oid'][:7]}")
            print(review["body"].strip())
    owners = {review["url"]: reviewer(review["body"]) for review in reviews}
    for thread in state.threads:
        show_thread(thread, owners)


def resolve(thread_id: str) -> None:
    command = ["gh", "api", "graphql", "-f", f"query={RESOLVE}", "-f", f"id={thread_id}"]
    answer = json.loads(github(command, deadline_from_now(), f"thread {thread_id}"))
    try:
        resolved = answer["data"]["resolveReviewThread"]["thread"]["isResolved"]
    except (KeyError, TypeError) as error:
        raise RefusalError("GitHub did not confirm the thread state.") from error
    if not resolved:
        raise RefusalError(f"Thread {thread_id} is still unresolved.")
    print(f"resolved {thread_id}")


def view(number: int, deadline: float) -> dict[str, str]:
    fields = "url,headRefOid,baseRefOid,baseRefName,mergeable"
    command = ["gh", "pr", "view", str(number), *repo_args(), "--json", fields]
    pr = object_fields(json.loads(github(command, deadline, f"PR {number}")), f"PR {number}")
    for key in fields.split(","):
        require_type(pr.get(key), str, f"PR {number} {key}")
    return {key: str(pr[key]) for key in fields.split(",")}


def configured_checks(repo: str, base_ref: str, deadline: float) -> list[str]:
    """The status check contexts the base branch's effective rules require."""
    path = f"repos/{repo}/rules/branches/{base_ref}?per_page=100"
    output = github(["gh", "api", path], deadline, f"{base_ref} rules")
    rules = object_list(json.loads(output), f"{base_ref} rules")
    if len(rules) >= 100:
        raise RefusalError(f"{base_ref} has 100 or more rules; read incomplete")
    contexts: list[str] = []
    for rule in rules:
        if rule.get("type") == "required_status_checks":
            parameters = object_fields(rule.get("parameters"), "required_status_checks")
            items = object_list(parameters.get("required_status_checks"), "required checks")
            contexts += [str(item.get("context")) for item in items]
    return list(dict.fromkeys(contexts))


def reported_checks(number: int, deadline: float) -> list[dict[str, object]]:
    """Every check reported on the PR head."""
    fields = "name,workflow,bucket,link"
    command = ["gh", "pr", "checks", str(number), *repo_args(), "--json", fields]
    left = deadline - time.monotonic()
    try:
        result = execute(command, timeout=left) if left > 0 else None
    except subprocess.TimeoutExpired:
        result = None
    if result is None:
        raise RefusalError(f"checks read incomplete after {READ_SECONDS}s")
    # gh exits 1 when a check failed and 8 when one is pending; the rows say which.
    if result.stdout.lstrip().startswith("["):
        return object_list(json.loads(result.stdout), "checks")
    if result.stderr.startswith("no checks reported"):
        return []
    raise RefusalError(result.stderr.strip() or f"gh pr checks exited {result.returncode}")


def check_identity(row: dict[str, object]) -> str:
    """A check's stable identity: its workflow and name."""
    return "check:" + "/".join(str(row[key]) for key in ("workflow", "name") if row.get(key))


def check_evidence(
    repo: str, number: int, base_ref: str, deadline: float
) -> tuple[tuple[Check, ...] | None, tuple[Check, ...], list[str]]:
    """Required checks, optional checks, and why required evidence is missing. A required
    context that has not reported is unavailable, never passing."""
    try:
        contexts = configured_checks(repo, base_ref, deadline)
        rows = reported_checks(number, deadline)
    except (RuntimeError, ValueError) as error:
        return None, (), [f"required checks unavailable: {error}"]
    checks = [
        Check(
            check_identity(row),
            str(row.get("name")),
            str(row.get("bucket")),
            str(row.get("link") or ""),
        )
        for row in rows
    ]
    required = tuple(check for check in checks if check.name in contexts)
    optional = tuple(check for check in checks if check.name not in contexts)
    reported = {check.name for check in required}
    gaps = [f"required check {name} not reported" for name in contexts if name not in reported]
    return required, optional, gaps


def latest_reviews(reviews: list[Any], head: str) -> dict[str, Review]:
    """Each reviewer entry's latest submitted review of this head; older heads do not count."""
    latest: dict[str, Review] = {}
    for review in reviews:
        lines = [line.strip() for line in str(review["body"]).splitlines() if line.strip()]
        commit: Any = review.get("commit") or {}
        if review["state"] != "PENDING" and len(lines) > 1 and commit.get("oid") == head:
            latest[lines[1].split(",")[0].strip()] = Review(lines[0] == "LGTM", review["url"])
    return latest


def review_evidence(
    repo: str, number: int, deadline: float
) -> tuple[list[Any] | None, list[Any] | None, str]:
    """All reviews and the unresolved threads, or None and the reason."""
    try:
        reviews = connection(repo, number, "reviews", REVIEW_FIELDS, deadline)
        threads = connection(repo, number, "reviewThreads", THREAD_FIELDS, deadline)
    except (RuntimeError, ValueError) as error:
        return None, None, f"review evidence unavailable: {error}"
    return reviews, [thread for thread in threads if not thread["isResolved"]], ""


def read_state(number: int, deadline: float | None = None) -> PrState:
    """The single PR-state reader. Refuse evidence read while the head or base changed."""
    deadline = deadline or deadline_from_now()
    first = view(number, deadline)
    repo = repository_of(first["url"])
    checks, optional, gaps = check_evidence(repo, number, first["baseRefName"], deadline)
    reviews, threads, reviews_gap = review_evidence(repo, number, deadline)
    last = view(number, deadline)
    for key in ("headRefOid", "baseRefOid"):
        if first[key] != last[key]:
            raise RefusalError(
                f"PR {number} {key} changed from {first[key]} to {last[key]} during the read; "
                "nothing recorded. Read again."
            )
    mergeable = first["mergeable"]
    gaps += [reviews_gap] if reviews_gap else []
    if mergeable not in ("MERGEABLE", "CONFLICTING"):
        gaps.append(f"mergeability unavailable: GitHub reports {mergeable}")
        mergeable = UNAVAILABLE
    return PrState(
        number=number,
        url=first["url"],
        head=first["headRefOid"],
        base=first["baseRefOid"],
        base_ref=first["baseRefName"],
        mergeable=mergeable,
        checks=checks,
        optional=optional,
        reviews=None if reviews is None else latest_reviews(reviews, first["headRefOid"]),
        review_nodes=tuple(reviews or ()),
        threads=None if threads is None else tuple(threads),
        unavailable=tuple(gaps),
    )


def valid_marker(fields: dict[str, object]) -> bool:
    """An open event may supersede earlier event IDs; a resolution names one event ID."""
    earlier = fields.get("supersedes", [])
    if fields.get("state") == "open":
        event = isinstance(earlier, list) and all(
            type(e) is int for e in cast(list[object], earlier)
        )
    else:
        event = fields.get("state") == "resolved" and type(fields.get("resolves")) is int
    return (
        event
        and fields.get("v") == MARKER_VERSION
        and type(fields.get("pr")) is int
        and all(isinstance(fields.get(key), str) for key in ("check", "head", "base"))
    )


def comment_id(url: str) -> int:
    match = COMMENT_ID.search(url)
    if not match:
        raise RuntimeError(f"No comment ID in {url!r}")
    return int(match.group(1))


def markers(comment: dict[str, object]) -> list[dict[str, Any]]:
    """The TEAM_FINDING markers of a FINDING comment; a malformed one blocks the fold."""
    lines = str(comment.get("body") or "").splitlines()
    header = HEADER.match(lines[0]) if lines else None
    if not header or header["type"] != "FINDING":
        return []
    found: list[dict[str, Any]] = []
    for line in lines[1:]:
        if line.startswith(MARKER):
            label = f"TEAM_FINDING in {comment.get('html_url')}"
            try:
                fields = object_fields(json.loads(line[len(MARKER) :]), label)
            except ValueError as error:
                raise RefusalError(f"Malformed {label}: {error}") from error
            if not valid_marker(fields):
                raise RefusalError(f"Malformed {label}")
            found.append(fields)
    return found


def findings(number: int, deadline: float) -> History:
    """Fold the PR's FINDING comments by event. An open event stays open until a resolution
    names its comment ID or a later open event supersedes that ID; a resolution never
    closes another event of the same check, head and base."""
    opened: dict[int, tuple[Finding, str]] = {}
    closed: set[int] = set()
    latest: dict[Finding, str] = {}
    for comment in issue_comments(str(number), deadline):
        for fields in markers(comment):
            if fields["pr"] != number:
                continue
            url = str(comment["html_url"])
            key = Finding(fields["check"], fields["head"], fields["base"])
            latest[key] = url
            if fields["state"] == "open":
                opened[comment_id(url)] = (key, url)
                closed.update(fields.get("supersedes", []))
            else:
                closed.add(fields["resolves"])
    return History({i: e for i, e in opened.items() if i not in closed}, latest)


def by_finding(events: dict[int, tuple[Finding, str]]) -> dict[Finding, str]:
    """Each open finding with the URL of its first open event."""
    found: dict[Finding, str] = {}
    for finding, url in events.values():
        found.setdefault(finding, url)
    return found


def outcomes(state: PrState) -> tuple[dict[str, str], dict[str, str]]:
    """Failed and passed evidence by check; unavailable or pending evidence is in neither."""
    failed: dict[str, str] = {}
    passed: dict[str, str] = {}
    at = f"head {state.head} and base {state.base_ref} {state.base}"
    if state.mergeable == "CONFLICTING":
        failed[MERGEABILITY] = f"Merge conflict at {at}."
    elif state.mergeable == "MERGEABLE":
        passed[MERGEABILITY] = f"Mergeable at {at}."
    for check in state.checks or ():
        evidence = f"Required {check.identity}: {check.bucket} at {at}: {check.link}"
        if check.bucket in FAILED:
            failed[check.identity] = evidence
        elif check.bucket in PASSED:
            passed[check.identity] = evidence
    return failed, passed


def record(
    number: int,
    finding: Finding,
    event: dict[str, Any],
    text: str,
    author: tuple[str, str, str],
    deadline: float,
) -> str:
    """Post one FINDING event without rereading the history the caller already folded.
    `event` holds the state and the event IDs it resolves or supersedes."""
    fields: dict[str, Any] = {
        "v": MARKER_VERSION,
        "pr": number,
        "check": finding.check,
        "head": finding.head,
        "base": finding.base,
        **event,
    }
    marker = MARKER + json.dumps(fields, separators=(",", ":"))
    body = "\n".join([comment_header("FINDING", *author), marker, text])
    return add_comment(str(number), body, deadline)


def unrecorded(number: int, failed: dict[str, str], error: Exception) -> RefusalError:
    """The known failures that could not be recorded, with the exact error."""
    known = " ".join(failed.values()) or "No failure observed, but the history is unreadable."
    return RefusalError(f"Known failure not recorded on PR {number}: {known} Error: {error}")


def observe(
    number: int, author: tuple[str, str, str], head: str = ""
) -> tuple[PrState, dict[Finding, str]]:
    """Read the PR, record its failures and resolutions as `author`, and return the state
    with the open findings and their URLs. One deadline bounds every read and write.

    The history is read once, before the state. Passing evidence resolves only the events
    that history showed open, each by its ID; an event posted during the read, even for the
    same check, head and base, stays open for the next observation. An open finding is not
    posted again. A new head or base resolves nothing.
    """
    deadline = deadline_from_now()
    try:
        history, history_error = findings(number, deadline), None
    except (RuntimeError, ValueError) as error:
        history, history_error = History({}, {}), error
    state = read_state(number, deadline)
    if head and state.head != head:
        raise RefusalError(f"PR {number} moved from {head} to {state.head}; nothing sent")
    failed, passed = outcomes(state)
    if history_error:
        raise unrecorded(number, failed, history_error)
    try:
        current = record_outcomes(state, author, deadline, history, failed, passed)
    except (RuntimeError, OSError, ValueError) as error:
        raise unrecorded(number, failed, error) from error
    return state, current


def record_outcomes(
    state: PrState,
    author: tuple[str, str, str],
    deadline: float,
    history: History,
    failed: dict[str, str],
    passed: dict[str, str],
) -> dict[Finding, str]:
    """Post new failures, their supersessions and resolutions; return the open findings."""
    events = dict(history.open)
    for check, evidence in failed.items():
        key = Finding(check, state.head, state.base)
        if key in by_finding(events):
            continue
        earlier = {i: url for i, (finding, url) in events.items() if finding.check == check}
        text = evidence + "".join(f" Supersedes {url}." for url in earlier.values())
        if key in history.latest:
            text += f" Reopens after {history.latest[key]}."
        event: dict[str, Any] = {"state": "open"}
        if earlier:
            event["supersedes"] = list(earlier)
        url = record(state.number, key, event, text, author, deadline)
        for i in earlier:
            del events[i]
        events[comment_id(url)] = (key, url)
    for check, evidence in passed.items():
        for i, (finding, url) in [(i, e) for i, e in events.items() if e[0].check == check]:
            event = {"state": "resolved", "resolves": i}
            record(state.number, finding, event, f"{evidence} Resolves {url}.", author, deadline)
            del events[i]
    return by_finding(events)


def review_gaps(reviews: dict[str, Review], required: list[str], head: str) -> list[str]:
    gaps: list[str] = []
    for entry in required:
        review = reviews.get(entry)
        if review is None:
            gaps.append(f"{entry} has not reviewed head {head}")
        elif not review.lgtm:
            gaps.append(f"{entry}'s latest review of this head has findings: {review.url}")
    return gaps


def blockers(state: PrState, required: list[str], known: dict[Finding, str]) -> list[str]:
    """Why the PR cannot merge at this head; empty when it can."""
    reasons = [*state.unavailable, *(f"open finding {url}" for url in known.values())]
    pending = [check for check in state.checks or () if check.bucket not in PASSED]
    reasons += [f"{check.identity} is {check.bucket}" for check in pending]
    if state.reviews is not None:
        reasons += review_gaps(state.reviews, required, state.head)
    if state.threads:
        reasons.append(f"{len(state.threads)} unresolved review threads")
    return reasons


def print_state(state: PrState, known: dict[Finding, str]) -> None:
    print(f"head {state.head}\nbase {state.base_ref} {state.base}\nmergeable {state.mergeable}")
    if state.checks == () and not any(g.startswith("required") for g in state.unavailable):
        print("no required checks configured")
    for check in state.checks or ():
        print(f"{check.identity} {check.bucket} {check.link}")
    for check in state.optional:
        print(f"optional {check.identity} {check.bucket} {check.link}")
    for finding, url in known.items():
        print(f"open finding {finding.check} at {finding.head[:7]}: {url}")


def observe_command(number: int) -> None:
    conf.configure()
    caller, me = team.caller_record()
    _, _, briefs = pull_request(str(number))
    if caller["brief"] not in briefs:
        raise RefusalError(f"PR {number} does not close your brief #{caller['brief']}")
    state, known = observe(number, poster(caller["agents"][me]))
    print_state(state, known)
    reasons = blockers(state, team.required_reviewers(caller), known)
    if reasons:
        raise RefusalError("not ready to merge:\n- " + "\n- ".join(reasons))
    print(f"ready to merge at {state.head}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Read PR state, reviews and threads.")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Recent reviews and every unresolved thread")
    listing.add_argument("pr", type=int)
    listing.add_argument("--all", action="store_true", help="Reviews of every head")
    observing = commands.add_parser("observe", help="Record failures; say whether it can merge")
    observing.add_argument("pr", type=int)
    resolving = commands.add_parser("resolve", help="Resolve a thread you opened")
    resolving.add_argument("thread")
    args = parser.parse_args()
    if args.command == "list":
        show(args.pr, args.all)
    elif args.command == "observe":
        observe_command(args.pr)
    else:
        resolve(args.thread)


if __name__ == "__main__":
    try:
        main()
    except (RefusalError, RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"pr_review: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired as error:
        print(f"pr_review: {error}", file=sys.stderr)
        sys.exit(1)
