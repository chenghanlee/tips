#!/usr/bin/env python3
"""List PR reviews and unresolved review threads, and resolve a thread.

This script uses GraphQL because GitHub's REST API does not list or resolve review threads.
It prints the information authors and reviewers need to act on.
"""

import argparse
import json
import re
import subprocess
import sys
from typing import Any

from team import execute

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


class RefusalError(Exception):
    pass


def gh(*args: str) -> str:
    result = execute(["gh", *args])
    if result.returncode:
        raise RefusalError(result.stderr.strip() or result.stdout.strip() or "gh failed")
    return result.stdout.strip()


def pull_request(number: int) -> tuple[str, str, str]:
    """Return (owner/repo, PR url, head commit)."""
    pr = json.loads(gh("pr", "view", str(number), "--json", "headRefOid,url"))
    repo = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/pull/\d+", pr["url"])
    if not repo:
        raise RefusalError(f"Unexpected PR URL: {pr['url']}")
    return repo.group(1), pr["url"], pr["headRefOid"]


def connection(repo: str, number: int, name: str, fields: str) -> list[Any]:
    """Return every node in the connection; raise an error if any page is incomplete."""
    owner, repo_name = repo.split("/")
    query = QUERY.replace("CONNECTION", name).replace("FIELDS", fields)
    nodes: list[Any] = []
    after = ""
    while True:
        args = ["-f", f"owner={owner}", "-f", f"name={repo_name}", "-F", f"number={number}"]
        if after:
            args += ["-f", f"after={after}"]
        answer = json.loads(gh("api", "graphql", "-f", f"query={query}", *args))
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


def unresolved_threads(repo: str, number: int) -> list[Any]:
    threads = connection(repo, number, "reviewThreads", THREAD_FIELDS)
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


def main() -> None:
    parser = argparse.ArgumentParser(description="Read PR reviews and threads; resolve a thread.")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="Recent reviews and every unresolved thread")
    listing.add_argument("pr", type=int)
    listing.add_argument("--all", action="store_true", help="Reviews of every head")
    resolving = commands.add_parser("resolve", help="Resolve a thread you opened")
    resolving.add_argument("thread")
    args = parser.parse_args()
    if args.command == "list":
        show(args.pr, args.all)
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
