#!/usr/bin/env python3
"""Read a PR's state and record its failures; list reviews and threads; resolve a thread.

list only displays. observe reads the head, base, mergeability, required checks and review
evidence, records each real failure as a FINDING comment on the PR with a TEAM_FINDING marker
line, appends a resolution when later evidence shows a failure gone, and says whether the PR
can merge. Unavailable evidence records nothing and resolves nothing. GraphQL is used because
GitHub's REST API does not list or resolve review threads.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

import team
from team import (
    HEADER,
    READ_PAGES,
    READ_SECONDS,
    comment_header,
    execute,
    issue_comments,
    object_fields,
    object_list,
    post_comment,
    read_github,
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
STATES = ("open", "resolved")
PASSED = ("pass", "skipping")
FAILED = ("fail", "cancel")


class RefusalError(RuntimeError):
    pass


@dataclass(frozen=True)
class Check:
    identity: str
    bucket: str
    link: str


@dataclass(frozen=True)
class Review:
    lgtm: bool
    url: str


@dataclass(frozen=True)
class PrState:
    """One read of a PR. None, or UNAVAILABLE for mergeability, marks evidence GitHub did not
    give; `unavailable` says why."""

    number: int
    url: str
    head: str
    base: str
    base_ref: str
    mergeable: str
    checks: tuple[Check, ...] | None
    reviews: dict[str, Review] | None
    unresolved: int | None
    unavailable: tuple[str, ...]


@dataclass(frozen=True)
class Finding:
    """A failure's identity: the check (or mergeability) at one head and base."""

    check: str
    head: str
    base: str


def gh(*args: str) -> str:
    result = execute(["gh", *args])
    if result.returncode:
        raise RefusalError(result.stderr.strip() or result.stdout.strip() or "gh failed")
    return result.stdout.strip()


def repository_of(url: str) -> str:
    """The owner/repo of a PR URL."""
    repo = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+", url)
    if not repo:
        raise RefusalError(f"Unexpected PR URL: {url}")
    return repo.group(1)


def pull_request(number: int) -> tuple[str, str, str]:
    """Return (owner/repo, PR url, head commit)."""
    pr = json.loads(gh("pr", "view", str(number), "--json", "headRefOid,url"))
    return repository_of(pr["url"]), pr["url"], pr["headRefOid"]


def connection(
    repo: str, number: int, name: str, fields: str, deadline: float | None = None
) -> list[Any]:
    """Return every node in the connection; raise an error if the read is incomplete."""
    deadline = deadline or time.monotonic() + READ_SECONDS
    owner, repo_name = repo.split("/")
    query = QUERY.replace("CONNECTION", name).replace("FIELDS", fields)
    nodes: list[Any] = []
    after = ""
    for _ in range(READ_PAGES):
        args = ["-f", f"owner={owner}", "-f", f"name={repo_name}", "-F", f"number={number}"]
        if after:
            args += ["-f", f"after={after}"]
        command = ["gh", "api", "graphql", "-f", f"query={query}", *args]
        answer = json.loads(read_github(command, deadline, f"PR {number} {name}"))
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


def unresolved_threads(repo: str, number: int, deadline: float | None = None) -> list[Any]:
    threads = connection(repo, number, "reviewThreads", THREAD_FIELDS, deadline)
    return [thread for thread in threads if not thread["isResolved"]]


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
    repo, _, head = pull_request(number)
    reviews = [
        review
        for review in connection(repo, number, "reviews", REVIEW_FIELDS)
        if review["body"].strip() and review["state"] != "PENDING"
    ]
    # Body feedback has no thread to stay open, so the head before the latest is shown too.
    commits = list(dict.fromkeys(review["commit"]["oid"] for review in reviews))
    recent = commits if every_head else commits[-2:]
    print(f"head {head}")
    for review in reviews:
        if review["commit"]["oid"] in recent:
            print(f"\nreview {review['url']} {review['commit']['oid'][:7]}")
            print(review["body"].strip())
    owners = {review["url"]: reviewer(review["body"]) for review in reviews}
    for thread in unresolved_threads(repo, number):
        show_thread(thread, owners)


def resolve(thread_id: str) -> None:
    answer = json.loads(gh("api", "graphql", "-f", f"query={RESOLVE}", "-f", f"id={thread_id}"))
    try:
        resolved = answer["data"]["resolveReviewThread"]["thread"]["isResolved"]
    except (KeyError, TypeError) as error:
        raise RefusalError("GitHub did not confirm the thread state.") from error
    if not resolved:
        raise RefusalError(f"Thread {thread_id} is still unresolved.")
    print(f"resolved {thread_id}")


def view(number: int, deadline: float) -> dict[str, str]:
    fields = "url,headRefOid,baseRefOid,baseRefName,mergeable"
    command = ["gh", "pr", "view", str(number), "--json", fields]
    pr = object_fields(json.loads(read_github(command, deadline, f"PR {number}")), f"PR {number}")
    for key in fields.split(","):
        team.require_type(pr.get(key), str, f"PR {number} {key}")
    return {key: str(pr[key]) for key in fields.split(",")}


def check_identity(row: dict[str, object]) -> str:
    """A required check's stable identity: its workflow and name."""
    return "check:" + "/".join(str(row[key]) for key in ("workflow", "name") if row.get(key))


def required_checks(number: int, deadline: float) -> tuple[tuple[Check, ...] | None, str]:
    """The PR head's required checks, or None and the reason GitHub gave none."""
    fields = "name,workflow,bucket,link"
    command = ["gh", "pr", "checks", str(number), "--required", "--json", fields]
    left = deadline - time.monotonic()
    try:
        result = execute(command, timeout=left) if left > 0 else None
    except subprocess.TimeoutExpired:
        result = None
    if result is None:
        return None, f"required checks unavailable: read incomplete after {READ_SECONDS}s"
    try:
        # gh exits 1 when a check failed and 8 when one is pending; the rows say which.
        rows = object_list(json.loads(result.stdout), "required checks")
    except ValueError:
        reason = result.stderr.strip() or result.stdout.strip() or f"gh exit {result.returncode}"
        return None, f"required checks unavailable: {reason}"
    checks = tuple(
        Check(check_identity(row), str(row.get("bucket")), str(row.get("link") or ""))
        for row in rows
    )
    return checks, ""


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
    repo: str, number: int, head: str, deadline: float
) -> tuple[dict[str, Review] | None, int | None, str]:
    try:
        reviews = connection(repo, number, "reviews", REVIEW_FIELDS, deadline)
        threads = unresolved_threads(repo, number, deadline)
    except (RuntimeError, ValueError) as error:
        return None, None, f"review evidence unavailable: {error}"
    return latest_reviews(reviews, head), len(threads), ""


def read_state(number: int) -> PrState:
    """Read the PR's state; refuse evidence read while its head or base changed."""
    deadline = time.monotonic() + READ_SECONDS
    first = view(number, deadline)
    repo = repository_of(first["url"])
    checks, checks_gap = required_checks(number, deadline)
    reviews, unresolved, reviews_gap = review_evidence(repo, number, first["headRefOid"], deadline)
    last = view(number, deadline)
    for key in ("headRefOid", "baseRefOid"):
        if first[key] != last[key]:
            raise RefusalError(
                f"PR {number} {key} changed from {first[key]} to {last[key]} during the read; "
                "nothing recorded. Read again."
            )
    mergeable = first["mergeable"]
    gaps = [gap for gap in (checks_gap, reviews_gap) if gap]
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
        reviews=reviews,
        unresolved=unresolved,
        unavailable=tuple(gaps),
    )


def valid_marker(fields: dict[str, object]) -> bool:
    try:
        earlier = object_list(fields.get("supersedes", []), "supersedes")
    except ValueError:
        return False
    return (
        fields.get("v") == 1
        and type(fields.get("pr")) is int
        and fields.get("state") in STATES
        and all(isinstance(fields.get(key), str) for key in ("check", "head", "base"))
        and all(isinstance(e.get("head"), str) and isinstance(e.get("base"), str) for e in earlier)
    )


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


def findings(number: int) -> dict[Finding, tuple[str, str]]:
    """Fold the PR's FINDING comments by key: each finding's latest state and comment URL.

    Duplicate comments for one key are one finding. A finding another one supersedes is
    closed with state `superseded`.
    """
    folded: dict[Finding, tuple[str, str]] = {}
    for comment in issue_comments(str(number)):
        for fields in markers(comment):
            if fields["pr"] != number:
                continue
            url = str(comment["html_url"])
            key = Finding(fields["check"], fields["head"], fields["base"])
            folded[key] = (fields["state"], url)
            for earlier in fields.get("supersedes", []):
                key = Finding(fields["check"], earlier["head"], earlier["base"])
                if folded.get(key, ("",))[0] == "open":
                    folded[key] = ("superseded", url)
    return folded


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
    status: str,
    text: str,
    author: tuple[str, str, str],
    earlier: list[Finding],
) -> str:
    """Post one FINDING event; a failed post raises with the failure it could not record."""
    fields: dict[str, Any] = {
        "v": 1,
        "pr": number,
        "check": finding.check,
        "head": finding.head,
        "base": finding.base,
        "state": status,
    }
    if earlier:
        fields["supersedes"] = [{"head": e.head, "base": e.base} for e in earlier]
    marker = MARKER + json.dumps(fields, separators=(",", ":"))
    body = "\n".join([comment_header("FINDING", *author), marker, text])
    try:
        return post_comment(str(number), body)
    except (RuntimeError, OSError, ValueError) as error:
        raise RefusalError(
            f"Known failure not recorded on PR {number}: {text} Error: {error}"
        ) from error


def observe(state: PrState, author: tuple[str, str, str]) -> dict[Finding, str]:
    """Record the state's failures and resolutions; return the open findings and their URLs.

    An identical open finding is not posted again. A new head or base does not resolve a
    finding; passing evidence for the same check does.
    """
    folded = findings(state.number)
    current = {key: url for key, (status, url) in folded.items() if status == "open"}
    failed, passed = outcomes(state)
    for check, evidence in failed.items():
        key = Finding(check, state.head, state.base)
        if key in current:
            continue
        earlier = [finding for finding in current if finding.check == check]
        text = evidence + "".join(f" Supersedes {current[e]}." for e in earlier)
        if key in folded:
            text += f" Reopens after {folded[key][1]}."
        current[key] = record(state.number, key, "open", text, author, earlier)
        for finding in earlier:
            del current[finding]
    for check, evidence in passed.items():
        for finding in [f for f in current if f.check == check]:
            text = f"{evidence} Resolves {current.pop(finding)}."
            record(state.number, finding, "resolved", text, author, [])
    return current


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
    if state.unresolved:
        reasons.append(f"{state.unresolved} unresolved review threads")
    return reasons


def observe_command(number: int) -> None:
    team.configure()
    caller, me = team.caller_record()
    _, _, briefs = team.pull_request(str(number))
    if caller["brief"] not in briefs:
        raise RefusalError(f"PR {number} does not close your brief #{caller['brief']}")
    state = read_state(number)
    known = observe(state, team.poster(caller["agents"][me]))
    print(f"head {state.head}\nbase {state.base_ref} {state.base}\nmergeable {state.mergeable}")
    for check in state.checks or ():
        print(f"{check.identity} {check.bucket} {check.link}")
    for finding, url in known.items():
        print(f"open finding {finding.check} at {finding.head[:7]}: {url}")
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
