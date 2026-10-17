"""Read and post GitHub issue comments, PRs and brief rosters within shared deadlines."""

import json
import re
import subprocess
import time
from collections.abc import Sequence

import config as conf
from commands import object_fields, object_list, run
from config import (
    COMMENT_TYPES,
    HEADER,
    READ_PAGES,
    READ_SECONDS,
    RETIREMENT,
    ROLES,
    Allocation,
    Record,
    Reports,
    repository,
)


def reviewer_names(value: str) -> list[str]:
    """Return names from `Required reviews:`. Reject empty or duplicate names."""
    names = [name.strip() for name in value.split(",")]
    if not all(names) or len(set(names)) != len(names):
        raise ValueError("empty or repeated name in Required reviews")
    return names


def issue_line(body: str, label: str) -> str | None:
    match = re.search(rf"^{re.escape(label)}:[ \t]*(.*?)[ \t]*$", body, re.MULTILINE)
    return match.group(1) if match else None


def roster(brief: str) -> tuple[str, list[str], list[str]]:
    """Read the brief's implementer, testers and reviewing designers from configured entries.

    Read reviewer names from `Required reviews:`. Keep testers in the listed order;
    the first tester confirms the merge. Return testers and designers separately.
    """
    command = ["gh", "issue", "view", brief, *repo_args(), "--json", "body"]
    body = str(json.loads(github(command, deadline_from_now(), f"#{brief}")).get("body") or "")
    implementer = issue_line(body, "Implementer")
    reviews = issue_line(body, "Required reviews")
    if implementer is None or reviews is None:
        raise RuntimeError(f"Brief #{brief} needs an Implementer: and a Required reviews: line")
    try:
        names = reviewer_names(reviews)
    except ValueError as error:
        raise RuntimeError(f"Brief #{brief}: {error}") from error
    for name in (implementer, *names):
        if name not in conf.settings()["agents"]:
            raise RuntimeError(f"Brief #{brief} names {name!r}, which is not a configured entry")
    if conf.settings()["agents"][implementer]["role"] != "implementer":
        raise RuntimeError(f"Brief #{brief}: Implementer {implementer} is not an implementer entry")
    if implementer in names:
        raise RuntimeError(f"Brief #{brief}: implementer {implementer} cannot review its own PR")
    by_role = {
        role: [n for n in names if conf.settings()["agents"][n]["role"] == role] for role in ROLES
    }
    if by_role["implementer"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names implementer entries")
    if not by_role["tester"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names no tester")
    return implementer, by_role["tester"], by_role["designer"]


def header_session(session: str) -> str:
    """The session word of a comment header: `unknown` when no session is recorded."""
    return session or "unknown"


def comment_header(kind: str, role: str, name: str, session: str) -> str:
    """The attribution line `<TYPE> <role> <name> <session>`."""
    if kind not in COMMENT_TYPES:
        raise RuntimeError(f"Comment type must be one of {', '.join(COMMENT_TYPES)}")
    return f"{kind} {role} {name} {header_session(session)}"


def github(args: Sequence[str], deadline: float, label: str, input_text: str | None = None) -> str:
    """Run one GitHub call within its whole operation's deadline; a late call is incomplete."""
    incomplete = f"{label}: incomplete after the {READ_SECONDS}s deadline"
    left = deadline - time.monotonic()
    if left <= 0:
        raise RuntimeError(incomplete)
    try:
        return run(*args, timeout=left, input_text=input_text)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(incomplete) from error


def deadline_from_now() -> float:
    return time.monotonic() + READ_SECONDS


def repo_args() -> list[str]:
    return ["--repo", repository()]


def issue_comments(issue: str, deadline: float | None = None) -> list[dict[str, object]]:
    """Return issue comments oldest first, with id, html_url, body and created_at fields.

    Deduplication and finding folds need every comment, so a truncated read raises.
    """
    deadline = deadline or deadline_from_now()
    path = f"repos/{repository(deadline)}/issues/{issue}/comments?per_page=100"
    found: list[dict[str, object]] = []
    for page in range(1, READ_PAGES + 1):
        output = github(["gh", "api", f"{path}&page={page}"], deadline, f"#{issue} comments")
        batch = object_list(json.loads(output), f"#{issue} comments")
        found += batch
        if len(batch) < 100:
            return found
    raise RuntimeError(f"#{issue} has over {READ_PAGES * 100} comments; read incomplete")


def post_comment(issue: str, text: str, deadline: float | None = None) -> str:
    """If the same comment exists, return its URL. Otherwise, post it. The read and the
    write share one deadline."""
    deadline = deadline or deadline_from_now()
    for comment in issue_comments(issue, deadline):
        if comment.get("body") == text:
            return str(comment["html_url"])
    return add_comment(issue, text, deadline)


def add_comment(issue: str, text: str, deadline: float) -> str:
    """Post a comment without a duplicate check; the caller has already read the issue."""
    command = ["gh", "issue", "comment", issue, *repo_args(), "--body-file", "-"]
    return github(command, deadline, f"comment on #{issue}", input_text=text)


def event_role(allocation: Allocation) -> str:
    return allocation["role"].split()[-1]


def post_event(brief: str, allocation: Allocation, text: str) -> None:
    """Record a launch on the brief as the launched client, with its session ID.

    Usage reports match agent names to session logs through this EVENT. Posting is
    idempotent, and a rerun of the command posts an EVENT that is still missing.
    """
    header = comment_header(
        "EVENT", event_role(allocation), allocation["name"], allocation["session"]
    )
    try:
        url = post_comment(brief, f"{header}\n{text}")
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise RuntimeError(
            f"EVENT not recorded on #{brief}: {error}. Rerun this command once GitHub answers; "
            "it posts the EVENT if it is still missing"
        ) from error
    print(f"Recorded on #{brief}: {url}")


def event_posted(brief: str, allocation: Allocation, text: str) -> bool:
    """Whether the client's EVENT with this text is on the brief, under any session: a
    Codex session resolved after launch must not post a second EVENT."""
    name = allocation["name"]
    for comment in issue_comments(brief):
        lines = str(comment.get("body") or "").splitlines()
        header = HEADER.match(lines[0]) if lines else None
        client = header is not None and (header["type"], header["name"]) == ("EVENT", name)
        if client and lines[1:2] == [text]:
            return True
    return False


def pull_request(pr: str) -> tuple[str, str, list[str]]:
    """The PR's URL, head commit and closing-reference issue numbers."""
    fields = "headRefOid,url,closingIssuesReferences"
    command = ["gh", "pr", "view", pr, *repo_args(), "--json", fields]
    view = object_fields(json.loads(github(command, deadline_from_now(), f"PR {pr}")), f"PR {pr}")
    references = object_list(view.get("closingIssuesReferences") or [], f"PR {pr} closing issues")
    briefs = [str(issue.get("number")) for issue in references]
    return str(view.get("url")), str(view.get("headRefOid")), briefs


def poster(allocation: Allocation) -> tuple[str, str, str]:
    """The (role, name, session) attribution of comments the client posts."""
    return event_role(allocation), allocation["name"], allocation["session"]


def retirement_reports(record: Record) -> Reports:
    """Each allocation's latest retirement report on the issue that names its recorded
    launch; a report from an earlier launch is no evidence. Reports are advisory evidence."""
    launches = {a["id"]: a["launch"] for a in record["agents"].values()}
    reports: Reports = {}
    for comment in issue_comments(record["brief"]):
        lines = str(comment.get("body") or "").splitlines()
        header = HEADER.match(lines[0]) if lines else None
        if not header or header["type"] != "EVENT":
            continue
        for line in lines[1:]:
            if line.startswith(RETIREMENT):
                try:
                    fields = object_fields(json.loads(line[len(RETIREMENT) :]), "report")
                except ValueError:
                    continue  # a malformed report is no evidence
                ident = str(fields.get("id"))
                if fields.get("launch") and launches.get(ident) == fields.get("launch"):
                    reports[ident] = (fields, str(comment["html_url"]))
    return reports


def merged_brief(brief: str) -> bool:
    """Whether GitHub reports the brief closed by a merged PR. stop holds the store lock, so
    every read shares one timeouts.shell_seconds budget; a late answer keeps the record."""
    seconds = conf.settings()["timeouts"]["shell_seconds"]
    deadline = time.monotonic() + seconds

    def read(*args: str) -> object:
        try:
            return json.loads(run(*args, timeout=max(deadline - time.monotonic(), 0.01)))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                f"GitHub did not answer within {seconds} s whether #{brief} is closed by a "
                "merged PR; the record and reservation are kept"
            ) from error

    fields = "state,closedByPullRequestsReferences"
    view = object_fields(read("gh", "issue", "view", brief, *repo_args(), "--json", fields), brief)
    if view.get("state") != "CLOSED":
        return False
    for pr in object_list(view.get("closedByPullRequestsReferences") or [], f"#{brief} PRs"):
        state = read("gh", "pr", "view", str(pr.get("number")), *repo_args(), "--json", "state")
        if object_fields(state, "PR state").get("state") == "MERGED":
            return True
    return False
