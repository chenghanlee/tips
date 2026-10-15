"""The dispatcher's only tools: fixed harness operations served over MCP stdio.

agent/teams/dispatch starts Claude restricted, with no built-in tools and this one
server. Every tool takes typed IDs, enums or bounded text and calls the same harness
functions as the CLI. No tool runs a command string, reads a path or accepts a profile.
GitHub calls name the configured repository. Run with the locked environment
(requirements.lock); `python -E -s adapter.py` serves stdio until the client exits.
"""

import contextlib
import io
import json
import os
import subprocess
import threading
from collections.abc import Callable
from typing import Annotated, Any, Literal, cast

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import Field

import board
import pr_review
import team

# Responses stay small; full output lives in GitHub, Herdr or local logs.
RESPONSE_BYTES = 8192
# Project reads stop at 10 pages of 100 entries; more is reported as incomplete.
PROJECT_ITEMS = 1000
ENTRY_PATTERN = r"^[a-z0-9][a-z0-9-]*$"

Number = Annotated[int, Field(ge=1, le=99_999_999)]
Offset = Annotated[int, Field(ge=0, le=100_000_000)]
# GitHub REST ids, such as comment ids, already exceed 32 bits.
GitHubId = Annotated[int, Field(ge=1, le=2**63 - 1)]
Entry = Annotated[str, Field(pattern=ENTRY_PATTERN, max_length=40)]
Message = Annotated[str, Field(min_length=1, max_length=RESPONSE_BYTES)]
Title = Annotated[str, Field(min_length=1, max_length=256)]
Body = Annotated[str, Field(min_length=1, max_length=60_000)]
FieldValue = Annotated[str, Field(min_length=1, max_length=256)]
CommentType = Literal[
    "PROPOSAL", "CRITIQUE", "QUESTION", "ANSWER", "AGREE", "FINDING", "BLOCKED", "DONE", "EVENT"
]
PrState = Literal["open", "closed", "merged", "all"]
ERRORS = (
    RuntimeError,
    OSError,
    ValueError,
    KeyError,
    pr_review.RefusalError,
    subprocess.TimeoutExpired,
)
AMBIGUOUS = (
    " The request may have reached GitHub or Herdr before the failure. Read the current "
    "state before trying again; do not repeat it blindly."
)


class FixedServer(MCPServer):
    """Reject arguments a tool does not declare; the SDK would otherwise ignore them."""

    async def call_tool(
        self, name: str, arguments: dict[str, Any], context: Any = None
    ) -> Any:
        declared = {tool.name: tool.input_schema for tool in await self.list_tools()}
        if name in declared:
            allowed = set(cast(dict[str, object], declared[name].get("properties", {})))
            unknown = sorted(set(arguments) - allowed)
            if unknown:
                raise ToolError(f"{name} does not accept {', '.join(unknown)}")
        return await super().call_tool(name, arguments, context)


server = FixedServer(
    "tips",
    instructions="Tips dispatcher operations. Each tool is one fixed harness operation.",
)
lock = threading.Lock()


def cap(text: str) -> str:
    data = text.encode()
    if len(data) <= RESPONSE_BYTES:
        return text
    kept = data[:RESPONSE_BYTES].decode(errors="ignore")
    return kept + f"\n[truncated: {len(data) - RESPONSE_BYTES} more bytes]"


def page(text: str, offset: int) -> str:
    """The text from a character offset, cut to fit one response, with the next offset."""
    rest = text[offset:]
    kept = rest.encode()[: RESPONSE_BYTES - 100].decode(errors="ignore")
    if len(kept) < len(rest):
        kept += f"\n[more: call again with offset={offset + len(kept)}]"
    return kept


def operate(action: Callable[[], str | None], *, writes: bool = False) -> str:
    """Run one harness operation at a time and return its printed output, capped.

    Harness functions print progress; stdout is the MCP wire, so it is captured here.
    A failed operation reports what it printed first; a timed-out write is ambiguous.
    """
    output = io.StringIO()
    with lock, contextlib.redirect_stdout(output):
        try:
            result = action()
        except ERRORS as error:
            # A timed-out write may have taken effect; a refused or failed one reports why.
            note = AMBIGUOUS if writes and isinstance(error, subprocess.TimeoutExpired) else ""
            raise ToolError(cap(f"{output.getvalue()}Error: {error}.{note}")) from error
    if result is not None:
        output.write(result)
    return cap(output.getvalue() or "done")


def dispatcher() -> tuple[str, str, str]:
    """The header identity of the dispatcher's comments: role, name and its session."""
    return ("dispatcher", "dispatcher", os.environ.get("TIPS_DISPATCHER_SESSION", ""))


def gh(*args: str, input_text: str | None = None) -> str:
    """Run gh with a fixed operation shape, the configured repository and the GitHub deadline."""
    return team.run("gh", *args, input_text=input_text, timeout=team.github_seconds())


def settings() -> team.GitHubSettings:
    configured = team.github_settings()
    if not configured:
        raise RuntimeError("config.toml has no [github] table")
    return configured


def owner() -> str:
    return settings()["repository"].split("/")[0]


def approved_fields(project: int) -> list[str]:
    fields = settings()["projects"].get(str(project))
    if fields is None:
        raise RuntimeError(f"Project {project} is not configured for the dispatcher")
    return fields


# Team lifecycle


@server.tool()
def status() -> str:
    """Every allocation record with each client's live Herdr pane, name, kind, state and
    session, plus whether the recorded dispatcher process runs."""
    return operate(team.status)


@server.tool()
def start_pair(brief: Number) -> str:
    """Launch a released brief's implementer and merge-confirming tester (team.py start)."""
    return operate(lambda: team.start(str(brief)), writes=True)


@server.tool()
def launch_reviewer(pr: Number, entry: Entry) -> str:
    """Launch one additional required reviewer of the PR at its head (team.py review)."""
    return operate(lambda: team.review(str(pr), entry), writes=True)


@server.tool()
def start_design(spec: Number, entry: Entry) -> str:
    """Launch a configured designer entry for a spec in its own allocation (team.py design).
    The spec body names the lead and the critics."""
    return operate(lambda: team.design(str(spec), entry), writes=True)


@server.tool()
def prompt_agent(brief: Number, entry: Entry, text: Message) -> str:
    """Send a message to a recorded client of the brief, such as a handoff or an answer.
    Success means Herdr delivered it, not that the client acted on it."""
    return operate(lambda: team.prompt_agent(str(brief), entry, text), writes=True)


@server.tool()
def retire_team(brief: Number) -> str:
    """Retire a team (team.py stop). A brief must be closed by a merged PR; one closed
    without a merged PR is retired by the user by hand. The first call asks each client
    that launched for a retirement report and refuses. Each report messages you
    `<report URL> retired`; call again then. A client that never launched needs no report.
    Unpreserved work keeps everything."""
    return operate(lambda: team.stop_brief(str(brief)), writes=True)


# Pull requests


@server.tool()
def pr_state(pr: Number) -> str:
    """The PR's state, head and base, mergeability, closing issues and required checks."""

    def read() -> str:
        fields = (
            "number,url,state,isDraft,headRefOid,baseRefName,baseRefOid,mergeable,"
            "mergeStateStatus,closingIssuesReferences"
        )
        view = gh("pr", "view", str(pr), "--repo", settings()["repository"], "--json", fields)
        return view + "\n" + required_checks(pr)

    return operate(read)


def required_checks(pr: int) -> str:
    """Required checks as JSON; gh exits nonzero while checks fail or are pending."""
    result = team.execute(
        [
            "gh",
            "pr",
            "checks",
            str(pr),
            "--repo",
            settings()["repository"],
            "--required",
            "--json",
            "name,state,bucket,link",
        ],
        timeout=team.github_seconds(),
    )
    try:
        json.loads(result.stdout)
    except ValueError:
        return "required checks unavailable: " + (result.stderr.strip() or "no output")
    return result.stdout.strip()


@server.tool()
def pr_checks(pr: Number) -> str:
    """The PR's required checks with state and link."""
    return operate(lambda: required_checks(pr))


@server.tool()
def pr_list(state: PrState) -> str:
    """Up to 100 PRs in the given state: number, title, branch, head and URL."""
    fields = "number,title,headRefName,headRefOid,state,url"
    repository = settings()["repository"]
    args = ["pr", "list", "--repo", repository, "--state", state, "--limit", "100"]
    return operate(lambda: gh(*args, "--json", fields))


@server.tool()
def pr_read(pr: Number) -> str:
    """Recent reviews and every unresolved review thread of the PR (pr_review.py list)."""
    return operate(lambda: pr_review.show(pr, False))


# Issues and board


@server.tool()
def issue_read(issue: Number, offset: Offset = 0) -> str:
    """An issue's number, title, state, labels, URL and body, from a character offset.
    A long result ends with the offset to read the rest from."""
    fields = "number,title,state,labels,url,body"
    repository = settings()["repository"]
    args = ["issue", "view", str(issue), "--repo", repository, "--json", fields]
    return operate(lambda: page(gh(*args), offset))


@server.tool()
def issue_create(title: Title, body: Body) -> str:
    """Create an issue and return its URL. After an error, read before creating again."""
    repository = settings()["repository"]
    args = ["issue", "create", "--repo", repository, "--title", title, "--body-file", "-"]
    return operate(lambda: gh(*args, input_text=body), writes=True)


@server.tool()
def board_read(
    issue: Number, after_comment_id: GitHubId | None = None, offset: Offset = 0
) -> str:
    """An issue body and its comments, or only the comments after the given comment id,
    from a character offset. A long result ends with the offset to read the rest from."""
    return operate(lambda: page(board.read_text(str(issue), after_comment_id), offset))


@server.tool()
def board_post(issue: Number, comment_type: CommentType, body: Body) -> str:
    """Post a board comment as the dispatcher, with its session in the header."""
    return operate(lambda: board.post_as(str(issue), comment_type, dispatcher(), body), writes=True)


@server.tool()
def usage_summary(
    issues: Annotated[list[Number], Field(min_length=1, max_length=20)],
) -> str:
    """Token counts by model for each session the issues' launch EVENTs name."""
    return operate(lambda: board.usage_table([str(issue) for issue in issues]))


# Projects


@server.tool()
def project_read(project: Number) -> str:
    """A configured project's items: issue number, title and the approved field values."""

    def read() -> str:
        fields = approved_fields(project)
        items = project_items(project)
        lines = [item_line(item, fields) for item in items]
        if len(items) >= PROJECT_ITEMS:
            lines.append(f"[incomplete: stopped at {PROJECT_ITEMS} items]")
        return "\n".join(lines) or "no items"

    return operate(read)


def item_line(item: dict[str, object], fields: list[str]) -> str:
    content = team.object_fields(item.get("content") or {}, "item content")
    values = [f"{name}: {item.get(name.lower(), '')}" for name in fields]
    return " | ".join([f"#{content.get('number', '?')} {item.get('title', '')}", *values])


@server.tool()
def project_add_item(project: Number, issue: Number) -> str:
    """Add an issue of the configured repository to a configured project."""

    def add() -> str:
        approved_fields(project)
        url = f"https://github.com/{settings()['repository']}/issues/{issue}"
        args = ["project", "item-add", str(project), "--owner", owner(), "--url", url]
        return gh(*args, "--format", "json")

    return operate(add, writes=True)


@server.tool()
def project_set_field(project: Number, issue: Number, field: FieldValue, value: FieldValue) -> str:
    """Set one approved field of an issue's project item to an option name or text."""
    return operate(lambda: set_field(project, issue, field, value), writes=True)


def set_field(project: int, issue: int, field: str, value: str) -> str:
    if field not in approved_fields(project):
        raise RuntimeError(f"Field {field!r} is not approved for project {project}")
    number, account = str(project), owner()
    view = json.loads(gh("project", "view", number, "--owner", account, "--format", "json"))
    listed = json.loads(gh("project", "field-list", number, "--owner", account, "--format", "json"))
    definitions = team.object_list(team.object_fields(listed, "fields").get("fields"), "fields")
    definition = next((d for d in definitions if d.get("name") == field), None)
    if definition is None:
        raise RuntimeError(f"Project {project} has no field {field!r}")
    item = project_item(project, issue)
    target = ["--id", item, "--project-id", str(view["id"]), "--field-id", str(definition["id"])]
    options = team.object_list(definition.get("options") or [], "options")
    if options:
        option = next((o for o in options if o.get("name") == value), None)
        if option is None:
            names = ", ".join(str(o.get("name")) for o in options)
            raise RuntimeError(f"{field} has no option {value!r}; options: {names}")
        gh("project", "item-edit", *target, "--single-select-option-id", str(option["id"]))
    else:
        gh("project", "item-edit", *target, "--text", value)
    return f"#{issue}: {field} set to {value} in project {project}"


def project_items(project: int) -> list[dict[str, object]]:
    args = ["project", "item-list", str(project), "--owner", owner(), "--format", "json"]
    output = json.loads(gh(*args, "--limit", str(PROJECT_ITEMS)))
    return team.object_list(team.object_fields(output, "project").get("items"), "items")


def project_item(project: int, issue: int) -> str:
    items = project_items(project)
    repository = f"https://github.com/{settings()['repository']}/issues/{issue}"
    for item in items:
        content = team.object_fields(item.get("content") or {}, "item content")
        if content.get("url") == repository:
            return str(item["id"])
    if len(items) >= PROJECT_ITEMS:
        raise RuntimeError(f"#{issue} not among the first {PROJECT_ITEMS} items; incomplete read")
    raise RuntimeError(f"#{issue} is not in project {project}; add it first")


def sanitize_environment() -> None:
    """Drop cwd-relative PATH entries and Python path injection before any subprocess."""
    for key in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE"):
        os.environ.pop(key, None)
    entries = os.environ.get("PATH", "").split(os.pathsep)
    os.environ["PATH"] = os.pathsep.join(e for e in entries if os.path.isabs(e))


def main() -> None:
    sanitize_environment()
    team.configure()
    settings()
    # Harness commands run from the configured main checkout, never the client's cwd.
    os.chdir(team.main)
    server.run("stdio")


if __name__ == "__main__":
    main()
