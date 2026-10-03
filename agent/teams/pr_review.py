#!/usr/bin/env python3
"""List a PR's reviews and unresolved review threads, and resolve a thread.

GitHub's REST API neither lists nor resolves review threads. These are the GraphQL calls an
author or reviewer needs, with the output cut to what they act on.
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
    "comments(first: 100) { totalCount nodes { databaseId body } }"
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
    """Every node of one pull-request connection; an incomplete answer is refused, not returned."""
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
    for thread in threads:
        if thread["comments"]["totalCount"] > len(thread["comments"]["nodes"]):
            raise RefusalError(f"Thread {thread['id']} has more comments than one page returns.")
    return [thread for thread in threads if not thread["isResolved"]]


def place(thread: Any) -> str:
    return f"{thread['path']}:{thread['line'] or thread['originalLine']}"


def show(number: int, every_head: bool) -> None:
    repo, _, head = pull_request(number)
    print(f"head {head}")
    for review in connection(repo, number, "reviews", REVIEW_FIELDS):
        body = review["body"].strip()
        current = every_head or review["commit"]["oid"] == head
        if body and current and review["state"] != "PENDING":
            print(f"\nreview {review['url']} {review['commit']['oid'][:7]}\n{body}")
    for thread in unresolved_threads(repo, number):
        first, *replies = thread["comments"]["nodes"]
        print(f"\nthread {thread['id']} reply-to {first['databaseId']} {place(thread)}")
        print(first["body"].strip())
        for reply in replies:
            print("> " + reply["body"].strip().replace("\n", "\n> "))


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
    listing = commands.add_parser("list", help="Reviews on the head and every unresolved thread")
    listing.add_argument("pr", type=int)
    listing.add_argument("--all", action="store_true", help="Include reviews of earlier heads")
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
