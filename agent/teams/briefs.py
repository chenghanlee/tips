"""The text of every brief, handoff message and refusal sent to clients."""

from pathlib import Path

from config import Allocation, Record, agent_spec, allocation_paths, harness, live_name, project_of


def bootstrap_brief(allocation: Allocation, commit: str) -> str:
    """The first task: the worker prepares its own project. Startup loaded no repository
    instructions: the client starts in the allocation directory, outside the clone."""
    _, project, logs, _ = allocation_paths(allocation["id"])
    command = f"python3 {harness() / 'bootstrap.py'}" + (f" --commit {commit}" if commit else "")
    return (
        f"Your allocation is {allocation['id']}; your project is {project}. First run "
        f"{command}: it clones the repository into the project or reuses your clone, fetches "
        "dependencies and starts Dexter. Its full log is in "
        f"{logs}. If it fails, report blocked with its error and stop; do not prepare the "
        f"project another way. Then work only in {project}: read its AGENTS.md and "
        "agent/teams/README.md; they were not loaded at startup. "
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
        "Do not run git clean -x; it deletes the wrapper and index. When the dispatcher asks "
        f"you to retire, run python3 {harness() / 'retirement.py'} and end your turn: it "
        "posts your clone's state to the issue, tells the dispatcher and changes nothing."
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
        + f"Then read the brief with gh issue view {record['brief']}. Use the README restart "
        "rule to find whose turn it is. If yours, continue the workflow; otherwise end your "
        "turn and wait for a message. "
        + handoff
        + f"Put {entry}, <session> on line 2 of each review record; replace <session> with "
        "your session ID. " + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def turn_command(recipient: str) -> str:
    return f"python3 {harness() / 'team.py'} turn <pr> {recipient}"


def reviewer_brief(record: Record, entry: str, duty: str, pr: str, head: str) -> str:
    allocation = record["agents"][entry]
    tester = live_name(record["slot"], record["tester"])
    return (
        identity(record, entry, duty)
        + bootstrap_brief(allocation, head)
        + f"Review PR {pr} at {head} from your own clone. Follow the README reviewer steps. "
        "Never run team.py turn. Submit the README review record with "
        f"{entry}, <session> on line 2; replace <session> with your session ID. "
        "Then notify the merge-confirming tester with "
        f"herdr agent prompt {tester} '<your review URL>' and end your turn. "
        "When notified of a new head, the notice names the bootstrap command that moves "
        "your clone to it. " + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def design_brief(record: Record, entry: str) -> str:
    allocation = record["agents"][entry]
    return (
        identity(record, entry, "designer")
        + bootstrap_brief(allocation, "")
        + "Read agent/teams/roles/designer.md, then the spec with "
        f"gh issue view {record['brief']}; its body names the lead and the critics. Use "
        "agent/teams/board.py to read and post. "
        + dexter_brief(project_of(allocation) / ".dexter/dexter.sh")
    )


def launch_text(allocation: Allocation) -> str:
    return (
        f"launched {allocation['kind']} in {allocation['root']}; allocation "
        f"{allocation['id']}; database suffix {allocation['db_suffix']}; port {allocation['port']}"
    )


def findings_text(known: list[tuple[str, str]]) -> str:
    if not known:
        return ""
    return "Open findings: " + "; ".join(f"{check} {url}" for check, url in known) + ". "


def bootstrap_command(head: str) -> str:
    return f"python3 {harness() / 'bootstrap.py'} --commit {head}"


def tester_message(
    record: Record, pr: str, url: str, head: str, missing: list[str], known: list[tuple[str, str]]
) -> str:
    implementer, tester = record["implementer"], record["tester"]
    message = f"Your turn: review {url} at {head}. This handoff notified every launched "
    message += "required reviewer of this head"
    if missing:
        message += f" and asked the dispatcher to launch {', '.join(missing)}"
    message += ". " + findings_text(known)
    message += (
        f"Move your own clone to the head first: {bootstrap_command(head)}; it refuses a "
        "dirty clone. Follow agent/teams/roles/tester.md and "
        "agent/skills/review-software-correctness/SKILL.md from your clone and use the "
        "README PR review record. "
        f"Put {tester}, <session> on line 2; replace <session> with your session ID. "
        "When your review or any required reviewer's latest review of this head has findings, "
        f"run {turn_command(implementer).replace('<pr>', pr)}; do not wait for the other "
        f"reviews. Follow the README merge step when python3 {harness() / 'pr_review.py'} "
        f"observe {pr} reports ready to merge. After the merge, notify the dispatcher with "
        f"herdr agent prompt dispatcher '{url} done'."
    )
    return message


def reviewer_notice(record: Record, entry: str, url: str, head: str) -> str:
    tester = live_name(record["slot"], record["tester"])
    return (
        f"New head to review on {url}: {head}. Move your own clone to it with "
        f"{bootstrap_command(head)}; it refuses a dirty clone and never resets one. Review "
        f"the changes since your last review. Submit the README review record with {entry}, "
        f"<session> on line 2, then send its URL with herdr agent prompt {tester} "
        "'<review URL>'."
    )


def implementer_message(pr: str, url: str, known: list[tuple[str, str]]) -> str:
    tools = harness() / "pr_review.py"
    message = f"Your turn on {url}: run python3 {tools} list {pr} and "
    message += f"python3 {tools} observe {pr}. " + findings_text(known)
    message += (
        "Fix review findings, failed checks and open findings following "
        "agent/skills/implement-software/SKILL.md from your clone. Push your changes, then "
        "run turn to the tester again; it notifies every required reviewer. "
        "If blocked, follow the README blocker procedure."
    )
    return message


def conflict_refusal(head: str, links: list[str], conflict: str) -> str:
    if conflict == "unknown":
        return (
            f"Known merge conflict {', '.join(links)}, and GitHub has not reported "
            f"mergeability for {head} yet: rerun turn shortly. Nobody was notified."
        )
    return (
        f"Known merge conflict {', '.join(links)}: merge origin/main and push, or report "
        "blocked. Nobody was notified."
    )
