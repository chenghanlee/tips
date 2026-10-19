"""The text of every brief, handoff message and refusal sent to clients."""

from pathlib import Path

from config import Allocation, Record, agent_spec, allocation_paths, harness, live_name, project_of
from github import PullRequest, event_role


def bootstrap_brief(allocation: Allocation, commit: str) -> str:
    """The first task: the worker prepares its own project. Startup loaded no repository
    instructions: the client starts in the allocation directory, outside the clone."""
    _, project, logs, _ = allocation_paths(allocation["id"])
    command = f"python3 {harness() / 'bootstrap.py'}" + (f" --commit {commit}" if commit else "")
    role = f"agent/teams/roles/{event_role(allocation)}.md"
    return (
        f"Your allocation is {allocation['id']}; your project is {project}. First run "
        f"{command}: it clones the repository into the project or reuses your clone, fetches "
        "dependencies and starts Dexter. Its full log is in "
        f"{logs}. If it fails, report blocked with its error and stop; do not prepare the "
        f"project another way. Then work only in {project}: read its AGENTS.md, "
        f"agent/teams/roles/common.md and {role}; they were not loaded at startup. Read "
        "agent/teams/README.md sections only where those files or messages link them. "
    )


def dexter_brief(wrapper: Path) -> str:
    # The binary is shared by every checkout and the guide is not, so the binary's own
    # help defines the current syntax even when checkout docs are outdated.
    return (
        "Load the skills required by AGENTS.md from .agents/skills before reading Elixir code. "
        "Follow its navigation table and function-use checks. "
        f"Run TIPS_DEXTER={wrapper} through the shell for this project. "
        'Read "$TIPS_DEXTER" query --help and "$TIPS_DEXTER" lookup --help once; '
        "Their syntax and output override outdated checkout docs. "
        'After fetching or changing dependencies, run "$TIPS_DEXTER" reindex. '
        "Do not start another Elixir language server. The index may be outdated; "
        "check empty results with rg. Leave the daemon running on exit. "
        "Do not run git clean -x; it deletes the wrapper and index."
    )


def identity(record: Record, entry: str, duty: str) -> str:
    persona = agent_spec(record["agents"][entry]).get("persona")
    issue = "spec" if record["kind"] == "design" else "brief"
    text = f"You are {entry}, the {duty} for {issue} #{record['brief']}; your Herdr name is "
    text += f"{live_name(record['slot'], entry)}. "
    if persona:
        text += f"Your persona: {persona}. "
    return text


def pair_brief(record: Record, entry: str, duty: str) -> str:
    # A relaunched client gets this brief too, so it finds the turn instead of assuming it.
    allocation = record["agents"][entry]
    implementer, tester = record["implementer"], record["tester"]
    if entry == implementer:
        handoff = f"After each push, hand the head to the reviewers with {turn_command(tester)}. "
    else:
        handoff = f"Hand findings to the implementer with {turn_command(implementer)}. "
    return (
        identity(record, entry, duty)
        + bootstrap_brief(allocation, "")
        + f"Then read the brief with gh issue view {record['brief']}. Use the restart rule "
        "in the README Turns section, including pending decisions and current issue "
        "comments, to find whose turn it is. If yours, continue the workflow; otherwise end "
        "your turn and wait for a message. "
        + handoff
        + f"Put {entry}, <session> on line 2 of each review record; replace <session> with "
        "your session ID. " + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def turn_command(recipient: str) -> str:
    return f"python3 {harness() / 'team.py'} turn <pr> {recipient}"


REVIEW_STEPS = {
    "reviewing designer": 'Follow "Steps: reviewing designer" in agent/teams/roles/designer.md '
    "and agent/skills/review-software-design/SKILL.md. ",
    "additional tester": "Follow the review steps in agent/teams/roles/tester.md. ",
}


def reviewer_brief(record: Record, entry: str, duty: str, pr: PullRequest) -> str:
    allocation = record["agents"][entry]
    tester = live_name(record["slot"], record["tester"])
    return (
        identity(record, entry, duty)
        + bootstrap_brief(allocation, pr.head)
        + f"Review PR {pr.url} at {pr.head} from your own clone. "
        + REVIEW_STEPS[duty]
        + "Never run team.py turn. Submit the README review record with "
        f"{entry}, <session> on line 2; replace <session> with your session ID. "
        "Then notify the merge-confirming tester with "
        f"herdr agent prompt {tester} '<your review URL>' and end your turn. "
        "When notified of a new head, the notice names the bootstrap command that moves "
        "your clone to it. " + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def design_brief(record: Record, entry: str) -> str:
    allocation = record["agents"][entry]
    assignment = (
        "Read the assigned QUESTION and its evidence. For a named source SHA, run "
        f"python3 {harness() / 'bootstrap.py'} --commit <sha> in your own clone before "
        "deciding. Follow the designer role's bounded-question steps. "
        if record["kind"] == "brief"
        else "Follow the designer role's initial-design steps. "
    )
    return (
        identity(record, entry, "designer")
        + bootstrap_brief(allocation, "")
        + "Read the issue with "
        f"gh issue view {record['brief']}; it names the lead and any critics. "
        + assignment
        + "Use "
        "agent/teams/board.py to read and post. "
        + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def launch_text(allocation: Allocation) -> str:
    """The launch EVENT's text. It names the launch, so each launch has its own EVENT."""
    return (
        f"launched {allocation['kind']} in {allocation['root']}; allocation "
        f"{allocation['id']}; launch {allocation['launch']}; database suffix "
        f"{allocation['db_suffix']}; port {allocation['port']}"
    )


def failures_text(failures: list[str]) -> str:
    return "Current failures: " + "; ".join(failures) + ". " if failures else ""


def bootstrap_command(head: str) -> str:
    return f"python3 {harness() / 'bootstrap.py'} --commit {head}"


def tester_message(record: Record, pr: PullRequest, missing: list[str], failures: list[str]) -> str:
    implementer, tester = record["implementer"], record["tester"]
    message = f"Your turn: review {pr.url} at {pr.head}. This handoff notified every launched "
    message += "required reviewer of this head"
    if missing:
        message += f" and asked the dispatcher to launch {', '.join(missing)}"
    message += ". " + failures_text(failures)
    message += (
        f"Move your own clone to the head first: {bootstrap_command(pr.head)}; it refuses a "
        "dirty clone. Follow agent/teams/roles/tester.md and "
        "both agent/skills/review-software-correctness/SKILL.md and "
        "agent/skills/review-software-design/SKILL.md from your clone and use the "
        "README PR review record. "
        f"Put {tester}, <session> on line 2; replace <session> with your session ID. "
        "When your review or any required reviewer's latest review of this head has findings, "
        f"run {turn_command(implementer).replace('<pr>', pr.number)}; do not wait for the "
        f"other reviews. Follow the README merge step when python3 {harness() / 'pr_review.py'} "
        f"observe {pr.number} reports ready to merge. After the merge, notify the dispatcher "
        f"with herdr agent prompt dispatcher '{pr.url} done'."
    )
    return message


def reviewer_notice(record: Record, entry: str, pr: PullRequest) -> str:
    tester = live_name(record["slot"], record["tester"])
    return (
        f"New head to review on {pr.url}: {pr.head}. Move your own clone to it with "
        f"{bootstrap_command(pr.head)}; it refuses a dirty clone and never resets one. Follow "
        "your role's PR review steps. Review the full relevant PR change on your first "
        "review; otherwise review the changes since your last actual review. Earlier "
        f"design advice is not a PR review. Submit the README review record with {entry}, "
        f"<session> on line 2, then send its URL with herdr agent prompt {tester} "
        "'<review URL>'."
    )


def implementer_message(pr: PullRequest, failures: list[str]) -> str:
    tools = harness() / "pr_review.py"
    message = f"Your turn on {pr.url}: run python3 {tools} list {pr.number} and "
    message += f"python3 {tools} observe {pr.number}. " + failures_text(failures)
    message += (
        "Fix review findings, failed checks and merge conflicts following "
        "agent/skills/implement-software/SKILL.md from your clone. Push your changes, then "
        "run turn to the tester again; it notifies every required reviewer. "
        "If blocked, follow the README blocker procedure."
    )
    return message


def conflict_refusal(head: str, mergeable: str) -> str:
    """Why a head whose mergeability is CONFLICTING or UNAVAILABLE is not handed off."""
    if mergeable == "CONFLICTING":
        return (
            f"Merge conflict at {head}: merge origin/main and push, or report blocked. "
            "Nobody was notified."
        )
    return (
        f"GitHub has not reported mergeability for {head} yet (mergeable {mergeable}): "
        "rerun turn shortly. Nobody was notified."
    )
