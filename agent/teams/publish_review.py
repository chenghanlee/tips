#!/usr/bin/env python3
"""Publish the tips/independent-review status for an approving review of the exact PR head.

The record is a submitted GitHub review of the head commit whose first line is `LGTM` and whose
second line names the reviewer. Every review thread on the PR must be resolved.
"""

import argparse
import json
import re
import subprocess
import sys
from typing import Any
from urllib.parse import urlparse

from pr_review import RefusalError, gh, place, pull_request, unresolved_threads

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
    source.add_argument("--record", help="Link to the approving review (#pullrequestreview-id)")
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


def publish_record(number: int, sha: str, record: str) -> None:
    path = review_api_path(record)
    repo, url = verified_pr(number, sha)
    if not record.startswith(url + "#"):
        raise RefusalError(f"Record {record} does not belong to PR {url}.")
    problem = approval_problem(json.loads(gh("api", path)), sha)
    if problem:
        raise RefusalError(problem)
    open_threads = unresolved_threads(repo, number)
    if open_threads:
        places = ", ".join(place(thread) for thread in open_threads)
        raise RefusalError(f"{len(open_threads)} unresolved review threads: {places}")
    post_status(repo, sha, record, "LGTM on this head; review threads resolved")
    print(f"Published {CONTEXT} on {sha} -> {record}")


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
