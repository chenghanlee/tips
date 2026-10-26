"""Read and post GitHub issue comments, PRs and brief rosters within shared deadlines."""

import json
import re
import subprocess
import time
from collections.abc import Sequence
from typing import Literal, NamedTuple

import config as conf
from commands import execute, object_fields, object_list, run
from config import (
    COMMENT_TYPES,
    HEADER,
    READ_PAGES,
    ROLES,
    UX_ROLES,
    Allocation,
    repository,
)

# The user's approval of a UX candidate: a comment that begins with this record. Agent
# comments begin with a harness header, so none of them matches (README.md#ux-design-team).
APPROVAL = re.compile(r"^APPROVED candidate [0-9a-f]{40}\b")


class PullRequest(NamedTuple):
    number: str
    url: str
    head: str
    briefs: list[str]  # the issues the PR closes
    base_ref: str

    def require_closes(self, brief: str) -> None:
        if brief not in self.briefs:
            raise RuntimeError(
                f"PR {self.number} does not close brief #{brief} (closes "
                f"{self.briefs or 'nothing'}); fix the PR's closing reference first"
            )


def reviewer_names(value: str, label: str = "Required reviews") -> list[str]:
    """Return the names of a comma-separated roster line. Reject empty or duplicate names."""
    names = [name.strip() for name in value.split(",")]
    if not all(names) or len(set(names)) != len(names):
        raise ValueError(f"empty or repeated name in {label}")
    return names


def issue_line(body: str, label: str) -> str | None:
    match = re.search(rf"^{re.escape(label)}:[ \t]*(.*?)[ \t]*$", body, re.MULTILINE)
    return match.group(1) if match else None


def issue_body(issue: str) -> str:
    command = ["gh", "issue", "view", issue, *repo_args(), "--json", "body"]
    return str(json.loads(github(command, deadline_from_now(), f"#{issue}")).get("body") or "")


# The two reserved label prefixes: the issue's workflow step and its coordinating owner.
WORKFLOW = ("phase:", "turn:")
Phase = Literal["design", "implement", "review"]


def label_failure(issue: str, result: subprocess.CompletedProcess[str], held: list[str]) -> str:
    error = result.stderr.strip() or result.stdout.strip() or "gh issue edit failed"
    return f"Label update of #{issue} failed: {error}. Its labels: {', '.join(held) or 'none'}"


def replace_labels(issue: str, prefixes: Sequence[str], new: Sequence[str]) -> None:
    """Replace the issue's labels that start with one of the prefixes by `new`, leaving every
    other label alone. gh runs the two halves of one edit separately, so a failed add would
    still remove: add first, then remove. A failure leaves the old labels, or old and new
    together, and names them. A label is created only when GitHub reports it missing. All
    calls share one GitHub deadline."""
    deadline = deadline_from_now()
    name = f"labels of #{issue}"
    command = ["gh", "issue", "view", issue, *repo_args(), "--json", "labels"]
    view = object_fields(json.loads(github(command, deadline, name)), name)
    held = [str(label.get("name")) for label in object_list(view.get("labels") or [], name)]
    add = [label for label in new if label not in held]
    remove = [label for label in held if label.startswith(tuple(prefixes)) and label not in new]
    edit = ["gh", "issue", "edit", issue, *repo_args()]
    created: list[str] = []
    while add:
        result = call([*edit, "--add-label", ",".join(add)], deadline, name)
        if not result.returncode:
            held += add
            break
        # gh names the first label the repository lacks: "failed to update <url>: 'x' not found".
        missing = re.search(r"'([^']+)' not found", result.stderr + result.stdout)
        if not missing or missing.group(1) not in add or missing.group(1) in created:
            raise RuntimeError(label_failure(issue, result, held))
        created.append(missing.group(1))
        github(["gh", "label", "create", created[-1], *repo_args()], deadline, name)
    if remove:
        result = call([*edit, "--remove-label", ",".join(remove)], deadline, name)
        if result.returncode:
            raise RuntimeError(label_failure(issue, result, held))


def give_turn_to_dispatcher(issue: str) -> None:
    """A blocker hands the issue's turn to the dispatcher; its phase stays."""
    replace_labels(issue, ("turn:",), ["turn:dispatcher"])


def spec_lead(spec: str) -> str:
    """The configured architect a standalone design issue names in its `Lead:` line."""
    lead = issue_line(issue_body(spec), "Lead") or ""
    agent = conf.settings()["agents"].get(lead)
    if agent is None or agent["role"] != "architect":
        raise RuntimeError(
            f"Spec #{spec} needs a `Lead: <entry>` line naming a configured architect; "
            f"it names {lead or 'none'}"
        )
    return lead


def roster(brief: str) -> tuple[str, list[str], list[str]]:
    """Read the brief's implementer, testers and reviewing architects from configured entries.

    Read reviewer names from `Required reviews:`. Keep testers in the listed order;
    the first tester confirms the merge. Return testers and architects separately.
    """
    body = issue_body(brief)
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
    refuse_ux_reviewers(brief, names)
    by_role = {
        role: [n for n in names if conf.settings()["agents"][n]["role"] == role] for role in ROLES
    }
    if by_role["implementer"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names implementer entries")
    if not by_role["tester"]:
        raise RuntimeError(f"Brief #{brief}: Required reviews names no tester")
    return implementer, by_role["tester"], by_role["architect"]


def refuse_ux_reviewers(brief: str, names: list[str]) -> None:
    """UX design team entries design before the pair; they never review its PR."""
    for name in names:
        role = conf.settings()["agents"][name]["role"]
        if role in UX_ROLES:
            raise RuntimeError(
                f"Brief #{brief}: Required reviews names {name}, a {role} entry; only tester "
                "and architect entries review"
            )


def ux_team(brief: str) -> tuple[str, list[str]] | None:
    """The brief's UX designer and graphic designers from its `UX:` and `Graphic designers:`
    lines, or None for a brief with neither line."""
    body = issue_body(brief)
    ux = issue_line(body, "UX")
    graphics = issue_line(body, "Graphic designers")
    if ux is None and graphics is None:
        return None
    if not ux or not graphics:
        raise RuntimeError(
            f"Brief #{brief} needs both a UX: entry and a Graphic designers: line naming at "
            "least one entry, or neither"
        )
    try:
        names = reviewer_names(graphics, "Graphic designers")
    except ValueError as error:
        raise RuntimeError(f"Brief #{brief}: {error}") from error
    agents = conf.settings()["agents"]
    for name, role in ((ux, "ux-designer"), *((n, "graphic-designer") for n in names)):
        if name not in agents:
            raise RuntimeError(f"Brief #{brief} names {name!r}, which is not a configured entry")
        if agents[name]["role"] != role:
            raise RuntimeError(f"Brief #{brief}: {name} is not a {role} entry")
    return ux, names


def approved_candidate(brief: str) -> bool:
    """Whether the user has posted the approval record of a UX candidate on the brief."""
    return any(
        APPROVAL.match(str(comment.get("body") or "").lstrip()) for comment in issue_comments(brief)
    )


def header_session(session: str) -> str:
    """The session word of a comment header: `unknown` when no session is recorded."""
    return session or "unknown"


def comment_header(kind: str, role: str, name: str, session: str) -> str:
    """The attribution line `<TYPE> <role> <name> <session>`."""
    if kind not in COMMENT_TYPES:
        raise RuntimeError(f"Comment type must be one of {', '.join(COMMENT_TYPES)}")
    return f"{kind} {role} {name} {header_session(session)}"


def call(
    args: Sequence[str], deadline: float, label: str, input_text: str | None = None
) -> subprocess.CompletedProcess[str]:
    """Run one GitHub call within its whole operation's deadline, whatever its exit status;
    a late call is incomplete."""
    incomplete = f"{label}: incomplete after the {conf.github_seconds()}s deadline"
    left = deadline - time.monotonic()
    if left <= 0:
        raise RuntimeError(incomplete)
    try:
        return execute(args, timeout=left, input_text=input_text)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(incomplete) from error


def github(args: Sequence[str], deadline: float, label: str, input_text: str | None = None) -> str:
    """Run one GitHub call within its operation's deadline; a failed call raises its error."""
    result = call(args, deadline, label, input_text)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{label} failed")
    return result.stdout.strip()


def deadline_from_now() -> float:
    """The deadline of one GitHub operation, however many calls it makes."""
    return time.monotonic() + conf.github_seconds()


def repo_args() -> list[str]:
    return ["--repo", repository()]


def issue_comments(issue: str, deadline: float | None = None) -> list[dict[str, object]]:
    """Return issue comments oldest first, with id, html_url, body and created_at fields.

    Deduplication and report folds need every comment, so a truncated read raises.
    """
    deadline = deadline or deadline_from_now()
    path = f"repos/{repository()}/issues/{issue}/comments?per_page=100"
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
    header = comment_header("EVENT", *poster(allocation))
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
    client = ("EVENT", allocation["name"])
    for comment in issue_comments(brief):
        parsed = parse_comment(comment)
        if parsed and (parsed[0]["type"], parsed[0]["name"]) == client and parsed[1][:1] == [text]:
            return True
    return False


def parse_comment(comment: dict[str, object]) -> tuple[re.Match[str], list[str]] | None:
    """The `<TYPE> <role> <name> <session>` header of a comment and its later lines; None
    for a comment without one."""
    lines = str(comment.get("body") or "").splitlines()
    header = HEADER.match(lines[0]) if lines else None
    return (header, lines[1:]) if header else None


def pull_request(number: str) -> PullRequest:
    """The PR's URL, head commit and closing-reference issue numbers."""
    fields = "headRefOid,url,closingIssuesReferences,baseRefName"
    command = ["gh", "pr", "view", number, *repo_args(), "--json", fields]
    label = f"PR {number}"
    view = object_fields(json.loads(github(command, deadline_from_now(), label)), label)
    references = object_list(view.get("closingIssuesReferences") or [], f"{label} closing issues")
    briefs = [str(issue.get("number")) for issue in references]
    return PullRequest(
        number, str(view.get("url")), str(view.get("headRefOid")), briefs, str(view["baseRefName"])
    )


def poster(allocation: Allocation) -> tuple[str, str, str]:
    """The (role, name, session) attribution of comments the client posts."""
    return event_role(allocation), allocation["name"], allocation["session"]


def merged_brief(brief: str) -> bool:
    """Whether GitHub reports the brief closed by a PR merged into main. stop holds the store
    lock, so every read shares one timeouts.shell_seconds budget; a late answer keeps the
    record."""
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
        number = str(pr.get("number"))
        state = object_fields(
            read("gh", "pr", "view", number, *repo_args(), "--json", "state,baseRefName"),
            "PR state",
        )
        if (state.get("state"), state.get("baseRefName")) == ("MERGED", "main"):
            return True
    return False
