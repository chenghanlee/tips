#!/usr/bin/env python3
"""Publish the tips/independent-review status only for a complete tech-lead review record."""

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
    parser.add_argument("--record", required=True, help="Link to the review record comment")
    return parser.parse_args()


def main() -> None:
    args = parse_arguments()
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        raise RefusalError("--sha must be a full 40-character commit id.")
    path = comment_api_path(args.record)
    record = json.loads(gh("api", path))["body"]
    missing = missing_sections(record)
    if missing:
        raise RefusalError("Review record is missing sections: " + ", ".join(missing))
    pr = json.loads(gh("pr", "view", str(args.pr), "--json", "headRefOid,headRepository,url"))
    if pr["headRefOid"] != args.sha:
        raise RefusalError(f"PR head is {pr['headRefOid']}, not the reviewed {args.sha}.")
    repo = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+", pr["url"])
    if not repo:
        raise RefusalError(f"Unexpected PR URL: {pr['url']}")
    gh(
        "api",
        "--method",
        "POST",
        f"repos/{repo.group(1)}/statuses/{args.sha}",
        "-f",
        f"context={CONTEXT}",
        "-f",
        "state=success",
        "-f",
        f"target_url={args.record}",
        "-f",
        "description=Tech lead review record complete",
    )
    print(f"Published {CONTEXT} on {args.sha} -> {args.record}")


if __name__ == "__main__":
    try:
        main()
    except (RefusalError, RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired as error:
        print(f"publish_review: {error}", file=sys.stderr)
        sys.exit(1)
