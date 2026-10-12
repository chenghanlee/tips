#!/usr/bin/env python3
"""Publish the tips/independent-review status for the approving reviews of the exact PR head.

A record is a submitted GitHub review of the head commit whose first line is `LGTM` and whose
second line names the reviewer. Every review thread on the PR must be resolved. When the PR's
issue names required reviewers (`Required reviews: name, name`), each of them must have an LGTM
as their latest review of the head; the caller's records cannot replace that list.
"""

import argparse
import json
import re
import subprocess
import sys
from typing import Any
from urllib.parse import urlparse

from pr_review import (
    REVIEW_FIELDS,
    RefusalError,
    connection,
    gh,
    place,
    pull_request,
    reviewer,
    unresolved_threads,
)

CONTEXT = "tips/independent-review"


def review_api_path(url: str) -> str:
    """Map a PR review link to its REST resource."""
    parsed = urlparse(url)
    match = re.fullmatch(r"/([^/]+)/([^/]+)/pull/(\d+)", parsed.path)
    review = re.fullmatch(r"pullrequestreview-(\d+)", parsed.fragment)
    if parsed.hostname != "github.com" or not match or not review:
        raise RefusalError("Record must be a github.com PR review link (#pullrequestreview-id).")
    owner, repo, number = match.groups()
    return f"repos/{owner}/{repo}/pulls/{number}/reviews/{review.group(1)}"


def approval_problem(review: Any, sha: str) -> str | None:
    """Why this review cannot stand as the approval of `sha`, or None."""
    lines = [line.strip() for line in (review.get("body") or "").splitlines()]
    if review.get("state") not in ("COMMENTED", "APPROVED"):
        return f"Review state is {review.get('state')}, not a submitted comment or approval."
    if review.get("commit_id") != sha:
        return f"Review is on {review.get('commit_id')}, not the reviewed {sha}."
    if not lines or lines[0] != "LGTM":
        return "Review must start with a line containing only LGTM."
    if len(lines) < 2 or not lines[1]:
        return "The second line must name the reviewer's role and session."
    return None


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=f"Publish {CONTEXT} on a reviewed head.")
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--sha", required=True, help="Exact reviewed head commit")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--record",
        action="append",
        help="Link to an approving review (#pullrequestreview-id); repeat for each reviewer",
    )
    source.add_argument(
        "--owner-waiver",
        metavar="REASON",
        help="Skip independent review, only on the user's explicit instruction; give the reason",
    )
    return parser.parse_args()


def verified_pr(number: int, sha: str) -> tuple[str, str]:
    """Return (owner/repo, PR url) after checking the PR head is the given SHA."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RefusalError("--sha must be a full 40-character commit id.")
    repo, url, head = pull_request(number)
    if head != sha:
        raise RefusalError(f"PR head is {head}, not the reviewed {sha}.")
    return repo, url


def post_status(repo: str, sha: str, target: str, description: str) -> None:
    gh(
        "api",
        "--method",
        "POST",
        f"repos/{repo}/statuses/{sha}",
        "-f",
        f"context={CONTEXT}",
        "-f",
        "state=success",
        "-f",
        f"target_url={target}",
        "-f",
        f"description={description}",
    )


def required_reviewers(number: int) -> list[str]:
    """Reviewer names the PR's issue requires, from its `Required reviews:` line; [] if none."""
    body = json.loads(gh("pr", "view", str(number), "--json", "body")).get("body") or ""
    closes = re.search(r"\bCloses #(\d+)\b", body)
    if not closes:
        return []
    issue = json.loads(gh("issue", "view", closes.group(1), "--json", "body")).get("body") or ""
    line = re.search(r"^Required reviews:\s*(.+?)\s*$", issue, re.MULTILINE)
    if not line:
        return []
    return [name.strip() for name in line.group(1).split(",") if name.strip()]


def named(body: str, name: str) -> bool:
    """Whether the review's reviewer line is `name`, optionally followed by a session."""
    return re.match(re.escape(name) + r"(?:[,\s]|$)", reviewer(body)) is not None


def latest_records(repo: str, number: int, sha: str, names: list[str]) -> dict[str, str]:
    """Each required reviewer's current LGTM link on `sha`; refuse a missing or superseded one."""
    reviews = [
        review
        for review in connection(repo, number, "reviews", REVIEW_FIELDS)
        if review["commit"]["oid"] == sha and review["state"] != "PENDING"
    ]
    records: dict[str, str] = {}
    for name in names:
        theirs = [review for review in reviews if named(review["body"] or "", name)]
        if not theirs:
            raise RefusalError(f"Required review from {name} is missing on {sha}.")
        latest = theirs[-1]
        shape = {"state": latest["state"], "commit_id": sha, "body": latest["body"]}
        if approval_problem(shape, sha):
            raise RefusalError(f"{name}'s latest review on {sha} is not an LGTM: {latest['url']}")
        records[name] = latest["url"]
    return records


def publish_record(number: int, sha: str, records: list[str]) -> None:
    if len(set(records)) != len(records):
        raise RefusalError("The same record was given twice.")
    paths = [review_api_path(record) for record in records]
    repo, url = verified_pr(number, sha)
    for record, path in zip(records, paths, strict=True):
        if not record.startswith(url + "#"):
            raise RefusalError(f"Record {record} does not belong to PR {url}.")
        problem = approval_problem(json.loads(gh("api", path)), sha)
        if problem:
            raise RefusalError(problem)
    names = required_reviewers(number)
    required = latest_records(repo, number, sha, names)
    for record in records:
        if names and record not in required.values():
            raise RefusalError(f"Record {record} is not a required reviewer's current LGTM.")
    open_threads = unresolved_threads(repo, number)
    if open_threads:
        places = ", ".join(place(thread) for thread in open_threads)
        raise RefusalError(f"{len(open_threads)} unresolved review threads: {places}")
    who = f"LGTM from {', '.join(names)}" if names else "LGTM"
    post_status(repo, sha, records[0], f"{who} on this head; review threads resolved")
    print(f"Published {CONTEXT} on {sha} -> {records[0]}")


def publish_waiver(number: int, sha: str, reason: str) -> None:
    if len(reason) < 12:
        raise RefusalError("--owner-waiver needs a reason of at least 12 characters.")
    repo, url = verified_pr(number, sha)
    waiver = gh(
        "pr",
        "comment",
        str(number),
        "--body",
        f"**Owner waiver:** independent review skipped on {sha}. "
        f"Owner-authorized exception. Reason: {reason}",
    )
    if not re.fullmatch(re.escape(url) + r"#issuecomment-\d+", waiver):
        raise RefusalError(f"Unexpected waiver comment link: {waiver}")
    post_status(repo, sha, waiver, "Owner waiver: independent review skipped")
    print(f"Published {CONTEXT} on {sha} by owner waiver -> {waiver}")


def main() -> None:
    args = parse_arguments()
    if args.record:
        publish_record(args.pr, args.sha, args.record)
    else:
        publish_waiver(args.pr, args.sha, args.owner_waiver.strip())


if __name__ == "__main__":
    try:
        main()
    except (RefusalError, RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
