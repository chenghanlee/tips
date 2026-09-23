#!/usr/bin/env python3
"""Publish the tips/independent-review status only for a complete tech-lead review record.

The record is the tech lead's rolling PR comment; the round headed `## <sha prefix> ...` for the
reviewed head must carry all five `###` sections with text.
"""

import argparse
import json
import re
import subprocess
import sys
from urllib.parse import urlparse

from team import execute

CONTEXT = "tips/independent-review"
SECTIONS = (
    "Local correctness",
    "Downstream effects",
    "Whole-project fit",
    "Design challenge",
    "Defect pass",
)


class RefusalError(Exception):
    pass


def missing_sections(record: str) -> list[str]:
    """Name every required heading that is absent or has no text before the next heading."""
    missing: list[str] = []
    parts = re.split(r"^#{2,3}\s+(.+?)\s*$", record, flags=re.MULTILINE)
    bodies = {parts[i].strip().lower(): parts[i + 1].strip() for i in range(1, len(parts) - 1, 2)}
    for section in SECTIONS:
        if not bodies.get(section.lower()):
            missing.append(section)
    return missing


def review_round(record: str, sha: str) -> str:
    """The body of the one `## <sha prefix> ...` round in a rolling comment that names this head."""
    parts = re.split(r"^##[ \t]+(.+?)[ \t]*$", record, flags=re.MULTILINE)
    rounds = [(parts[i].split()[0].lower(), parts[i + 1]) for i in range(1, len(parts) - 1, 2)]
    matches = [
        body
        for prefix, body in rounds
        if re.fullmatch(r"[0-9a-f]{7,40}", prefix) and sha.startswith(prefix)
    ]
    if len(matches) != 1:
        raise RefusalError(f"Record needs exactly one '## {sha[:7]}…' round for the reviewed head.")
    return matches[0]


def comment_api_path(url: str) -> str:
    """Map a PR review-comment or issue-comment link to its REST resource."""
    parsed = urlparse(url)
    match = re.fullmatch(r"/([^/]+)/([^/]+)/pull/\d+", parsed.path)
    kind = re.fullmatch(r"issuecomment-(\d+)|discussion_r(\d+)", parsed.fragment)
    if parsed.hostname != "github.com" or not match or not kind:
        raise RefusalError("Record must be a github.com PR comment link with its #issuecomment-id.")
    owner, repo = match.group(1), match.group(2)
    if kind.group(1):
        return f"repos/{owner}/{repo}/issues/comments/{kind.group(1)}"
    return f"repos/{owner}/{repo}/pulls/comments/{kind.group(2)}"


def gh(*args: str) -> str:
    result = execute(["gh", *args])
    if result.returncode:
        raise RefusalError(result.stderr.strip() or result.stdout.strip() or "gh failed")
    return result.stdout.strip()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=f"Publish {CONTEXT} on a reviewed head.")
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--sha", required=True, help="Exact reviewed head commit")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--record", help="Link to the tech lead's review record comment")
    source.add_argument(
        "--owner-waiver",
        metavar="REASON",
        help="Owner-driven change with no team live: skip independent review for this reason",
    )
    return parser.parse_args()


def verified_pr(number: int, sha: str) -> tuple[str, str]:
    """Return (owner/repo, PR url) after checking the PR head is the given SHA."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RefusalError("--sha must be a full 40-character commit id.")
    pr = json.loads(gh("pr", "view", str(number), "--json", "headRefOid,url"))
    if pr["headRefOid"] != sha:
        raise RefusalError(f"PR head is {pr['headRefOid']}, not the reviewed {sha}.")
    repo = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+", pr["url"])
    if not repo:
        raise RefusalError(f"Unexpected PR URL: {pr['url']}")
    return repo.group(1), pr["url"]


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


def main() -> None:
    args = parse_arguments()
    if args.record:
        path = comment_api_path(args.record)
        record = json.loads(gh("api", path))["body"]
        missing = missing_sections(review_round(record, args.sha))
        if missing:
            raise RefusalError("Review record is missing sections: " + ", ".join(missing))
        repo, url = verified_pr(args.pr, args.sha)
        if not args.record.startswith(url + "#"):
            raise RefusalError(f"Record {args.record} does not belong to PR {url}.")
        post_status(repo, args.sha, args.record, "Tech lead review record complete")
        print(f"Published {CONTEXT} on {args.sha} -> {args.record}")
        return
    reason = args.owner_waiver.strip()
    if len(reason) < 12:
        raise RefusalError("--owner-waiver needs a reason of at least 12 characters.")
    repo, _ = verified_pr(args.pr, args.sha)
    waiver = gh(
        "pr",
        "comment",
        str(args.pr),
        "--body",
        f"**Owner waiver:** independent review skipped on {args.sha}. "
        f"No team live; owner-driven change. Reason: {reason}",
    )
    comment_api_path(waiver)  # gh prints the new comment URL; refuse anything else.
    post_status(repo, args.sha, waiver, "Owner waiver: independent review skipped")
    print(f"Published {CONTEXT} on {args.sha} by owner waiver -> {waiver}")


if __name__ == "__main__":
    try:
        main()
    except (RefusalError, RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
