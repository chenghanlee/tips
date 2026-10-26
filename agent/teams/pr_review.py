#!/usr/bin/env python3
"""Read a PR's state and say whether it can merge; list reviews and threads; resolve a thread;
hand a reviewer the PR body once its concerns are written.

handoff finds the open PR at a head and prints its URL, body, recent reviews and unresolved
threads. It refuses until the named concerns file exists and names that head, so the
reviewer's own reading of the brief, diff and tests comes before the implementer's account.
Both list and observe read through read_state and post nothing. observe judges only the
live state at the current head: an earlier failure that the current read no longer shows
does not block. The required checks are the contexts the base branch's effective rules
require. GraphQL is used because GitHub's REST API does not list or resolve review threads.
"""

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import config as conf
import team
from commands import object_fields, object_list, require_type
from config import READ_PAGES, repository
from github import call, deadline_from_now, github, pull_request, repo_args

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


def review_author(body: str) -> str:
    """The reviewer entry of a review body: line 2 is `<entry>, <session>`; "" without one."""
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    return lines[1].split(",")[0].strip() if len(lines) > 1 else ""


def show_thread(thread: Any, owners: dict[str, str]) -> None:
    first, *replies = thread["comments"]["nodes"]
    opened: Any = first["pullRequestReview"] or {}
    owner = owners.get(str(opened.get("url"))) or "unknown reviewer"
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
    owners = {review["url"]: review_author(review["body"]) for review in reviews}
    for thread in state.threads:
        show_thread(thread, owners)


def pulls_at(head: str, deadline: float) -> list[dict[str, Any]]:
    """The open PRs whose head is `head`, with their url, base and body."""
    label = f"PRs at {head[:7]}"
    path = f"repos/{repository()}/commits/{head}/pulls?per_page=100"
    pulls = object_list(json.loads(github(["gh", "api", path], deadline, label)), label)
    return [
        pr
        for pr in pulls
        if pr.get("state") == "open"
        and object_fields(pr.get("head"), f"{label} head").get("sha") == head
    ]


def handoff(head: str, concerns: Path) -> None:
    """Print the PR at `head`, its body, recent reviews and unresolved threads, once
    `concerns` names the head. The file is the reviewer's own reading, written first."""
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise RefusalError(f"{head!r} is not a full head SHA; use the one the handoff names")
    first = f"Read the brief, the diff and the tests first; write your concerns to {concerns}"
    try:
        text = concerns.read_text()
    except OSError as error:
        raise RefusalError(f"{first}: {error}") from error
    if head[:7] not in text:
        raise RefusalError(f"{first}; it does not name head {head[:7]}")
    pulls = pulls_at(head, deadline_from_now())
    if not pulls:
        raise RefusalError(f"No open PR has head {head}; wait for the handoff of the current head")
    if len(pulls) > 1:
        numbers = ", ".join(str(pr.get("number")) for pr in pulls)
        raise RefusalError(f"PRs {numbers} share head {head}; report blocked")
    pr = pulls[0]
    base = object_fields(pr.get("base"), "PR base").get("ref")
    print(f"PR {pr.get('html_url')} head {head} base {base}")
    print(f"--- PR body ---\n{str(pr.get('body') or '').strip()}\n--- reviews ---")
    show(int(str(pr["number"])), every_head=False)


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
    result = call(command, deadline, f"PR {number} checks")
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
        body = str(review["body"]).strip()
        author = review_author(body)
        commit: Any = review.get("commit") or {}
        if review["state"] != "PENDING" and author and commit.get("oid") == head:
            latest[author] = Review(body.splitlines()[0].strip() == "LGTM", review["url"])
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
                f"PR {number} {key} changed from {first[key]} to {last[key]} during the read. "
                "Read again."
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


def failures(state: PrState) -> list[str]:
    """What the implementer must fix at this head: a live merge conflict and each failed
    required check. Unavailable or pending evidence is not a failure."""
    found = [f"merge conflict at {state.head}"] if state.mergeable == "CONFLICTING" else []
    for check in state.checks or ():
        if check.bucket in FAILED:
            found.append(f"{check.identity} is {check.bucket}: {check.link}")
    return found


def review_gaps(reviews: dict[str, Review], required: list[str], head: str) -> list[str]:
    gaps: list[str] = []
    for entry in required:
        review = reviews.get(entry)
        if review is None:
            gaps.append(f"{entry} has not reviewed head {head}")
        elif not review.lgtm:
            gaps.append(f"{entry}'s latest review of this head has findings: {review.url}")
    return gaps


def blockers(state: PrState, required: list[str]) -> list[str]:
    """Why the PR cannot merge at this head, from the live state alone; empty when it can.
    Unknown mergeability is in `state.unavailable`, so it blocks too."""
    reasons = [*state.unavailable, *failures(state)]
    pending = [c for c in state.checks or () if c.bucket not in PASSED and c.bucket not in FAILED]
    reasons += [f"{check.identity} is {check.bucket}" for check in pending]
    if state.reviews is not None:
        reasons += review_gaps(state.reviews, required, state.head)
    if state.threads:
        reasons.append(f"{len(state.threads)} unresolved review threads")
    return reasons


def print_state(state: PrState) -> None:
    print(f"head {state.head}\nbase {state.base_ref} {state.base}\nmergeable {state.mergeable}")
    if state.checks == () and not any(g.startswith("required") for g in state.unavailable):
        print("no required checks configured")
    for check in state.checks or ():
        print(f"{check.identity} {check.bucket} {check.link}")
    for check in state.optional:
        print(f"optional {check.identity} {check.bucket} {check.link}")


def observe_command(number: int) -> None:
    conf.configure()
    caller, _ = team.caller_record()
    pull_request(str(number)).require_closes(caller["brief"])
    state = read_state(number)
    print_state(state)
    reasons = blockers(state, team.required_reviewers(caller))
    if reasons:
        raise RefusalError("not ready to merge:\n- " + "\n- ".join(reasons))
    print(f"ready to merge at {state.head}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Read PR state, reviews and threads.")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Recent reviews and every unresolved thread")
    listing.add_argument("pr", type=int)
    listing.add_argument("--all", action="store_true", help="Reviews of every head")
    observing = commands.add_parser("observe", help="Say whether it can merge at this head")
    observing.add_argument("pr", type=int)
    handing = commands.add_parser("handoff", help="The PR at a head, its body and reviews")
    handing.add_argument("head")
    handing.add_argument("concerns", type=Path, help="Your concerns file; it must name the head")
    resolving = commands.add_parser("resolve", help="Resolve a thread you opened")
    resolving.add_argument("thread")
    args = parser.parse_args()
    if args.command == "list":
        show(args.pr, args.all)
    elif args.command == "observe":
        observe_command(args.pr)
    elif args.command == "handoff":
        handoff(args.head, args.concerns)
    else:
        resolve(args.thread)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"pr_review: {error}", file=sys.stderr)
        sys.exit(1)
