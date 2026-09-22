# Agent teams

Run the commands below from the repository root. This directory contains the team
launchers and configuration; `tests/` contains their integration tests. Shared
Elixir LSP tooling lives in `agent/lsp/`; see the
[LSP build and acceptance guide](../lsp/README.md).

This is the operating agreement for building Tips. [AGENTS.md](../../AGENTS.md) governs engineering. GitHub issues and PRs hold requirements, decisions, review history and evidence. [team configuration](config.toml) owns agent settings; do not duplicate its defaults in commands or prose.

The lead TPM coordinates assigned work in [Project 15](https://github.com/users/chenghanlee/projects/15), including child issues. Work continues within the user's assigned scope until completed or blocked on the user.

## Check changes to these scripts

From your task worktree, use Python 3.12 and the installed Ruff and Pyright tools:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

[Python check settings](pyproject.toml) follow the harness's Python profile: strict
types, a complexity limit of 10, and the same lint rules. The test assertion
exception applies only to Python files under `tests/`.
The scripts and tests use only the standard library.

Tests use disposable Git repositories, a fake Herdr CLI, and owned child processes.
They do not operate live teams. Process tests require permission to run `ps` and
signal their own children.

Ruff's two S603 findings remain unsuppressed: the shared command runner and the
process-test launcher accept variable argument lists. Review these calls for
trusted executable selection and argument handling; test success alone does not
prove subprocess safety.

## Roles

One lead TPM assigns work to teams within the configured trial limit. Each team handles one issue at a time.

| Role | Owns |
|---|---|
| Lead TPM (`lead-tpm`) | Assign issues, start/retire teams, resolve cross-team dependencies, report blockers to the user. |
| Team TPM (`team-N-tpm`) | Assess readiness, provision/advance coding sessions, dispatch, update issue labels, route handoffs. |
| Developer (`team-N-dev`) | Implement the issue with integration-first TDD; own its branch, worktree and PR. |
| Tester (`team-N-test`) | Independently review each pushed commit and run relevant verification. |
| Tech lead (`team-N-lead`) | Confirm technical readiness; deeply review the whole PR's design; publish its review status and merge. |

The team TPM alone advances review stages and dispatches or restarts coding sessions. Developers and reviewers report results to it; they do not dispatch the next reviewer. Technical leads concentrate on code review and retain merge ownership. Reviewers use the issue, code and evidence, with fresh sessions at each dispatched revision. Nobody reviews or merges their own implementation. The common GitHub identity cannot mechanically prove reviewer independence.

The user decides material product changes, purchases, credentials, hosting and public launch. Routine technical choices belong to the responsible role. No budget has been fixed; absence of a ceiling does not authorize purchases.

## Configuration

Edit [agent/teams/config.toml](config.toml) to change team limits, client/model/effort by role, port/database allocation, permission modes, coordinator compaction and time budgets. Scripts read the canonical main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged configuration for a disposable pilot. Settings take effect on the next launch. The patched bridge has a compiled request deadline; changing its corresponding client timeout requires rebuilding and retesting the bridge too.

The generated Codex config applies `launch.codex_lsp_approval_mode` only to the four enabled LSP tools. It leaves the overall approval and sandbox policies in place. This uses the [supported per-tool MCP setting](https://developers.openai.com/codex/mcp); `never` otherwise rejects a tool that requires approval.

Database suffixes combine `team.db_suffix_prefix`, the team number and `roles.<role>.db_suffix`. Test ports combine `team.port_base`, team number times `team.port_stride`, and the role's `port_offset`. The launcher exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV` and `TIPS_CHECK_TIMEOUT_SECONDS` directly to the coding process. Leave those computed resources in place for tests, including Wallaby.

## Task readiness

The lead TPM picks critical-path issues whose prerequisites are integrated and evidenced, preferring the team's current package. Package parent issues are not coding assignments. Split work into bounded changes a fresh agent can understand, implement, test and repair.

Before dispatch, the team TPM records one outcome, exclusions, exact design sections and real entry points, acceptance scenarios, runnable verification and available prerequisites. The tech lead confirms readiness on the issue, amending the technical contract when necessary. Discovery may be its own task. Do not require file ownership lists, reservations or overlap approval; coordinate concrete shared changes when they arise.

Each coding issue records acceptance-to-test mappings. Milestone gates require E2E evidence on one integrated revision; isolated task reports do not establish a gate. Closing a package requires its mandatory children and package acceptance evidence.

## Issue and project state

Use GitHub issues and PRs as the source of truth. Add `active` when assigned; add `blocked` when progress requires outside action, with the prerequisite, responsible role and next action in a comment. Remove stale labels as the situation changes. A waiting dependency is not automatically a user blocker. Do not mirror a workflow state machine into Project fields or maintain a separate status document.

An issue closes only when its required result is integrated and evidenced. Partial work uses `Refs #number`; a completing PR uses `Closes #number`. Child issues created during the run count toward the goal.

## Git

Use protected `main`, short-lived `task/<issue>-<slug>` branches and worktrees under `.worktrees/`. The main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there. Repository administration such as fetch and worktree creation runs from main. Make every source change in a worktree, including documentation and operational scripts.

The TPM uses `agent/teams/task_worktree.py` to provision and start coding clients. Keep the existing task slug when an issue is renamed. The developer owns its task worktree; tester and tech lead have separate detached review worktrees. No agent edits another's checkout. The helper checks reviewer cleanliness even at the same SHA, checks selected-client configuration before changing HEAD, reuses a matching live session, and stops the old client and verifies descendant exit before advancing a reviewer. `/new`, `/clear` and `cd` inside an already-running client do not reroot its LSP.

Open a draft PR early. Commit cohesive changes and run relevant checks before pushing. Unpushed local commits may be reorganized; published commits are fixed. Never force-push or push implementation directly to main. Repository rules block force pushes on `task/**` while permitting deletion of merged branches. Merge with merge commits; keep strict up-to-date checks and automatic deletion of merged remote heads.

## One-time setup

Before starting a team, install Python 3.11+ and the client CLIs selected in
[team configuration](config.toml), and authenticate those clients and GitHub CLI
(`gh`) for this repository. The merge commands also need GNU `timeout` on `PATH`.
On macOS, install it with `brew install coreutils`; on Linux, use your distribution's
`coreutils` package.

The required skills and Mix plugins come from
[Elixir Agent Tools](https://github.com/georgeguimaraes/elixir-agent-tools).
From the main checkout, install the pinned source and link its five skills:

```bash
git clone https://github.com/georgeguimaraes/elixir-agent-tools.git agent/elixir-agent-tools
git -C agent/elixir-agent-tools checkout --detach ac3a5a1661a087158b39d5eb742b3c25fe3c7b44
mkdir -p .agents/skills
for skill in elixir phoenix ecto otp oban; do
  ln -s "$PWD/agent/elixir-agent-tools/plugins/elixir-dev/skills/$skill" ".agents/skills/$skill"
done
```

These are ignored local dependencies. If a destination already exists, inspect it
before replacing it. The task launcher links the main checkout's `.agents/skills`
into each worktree; it does not download skills. Keep the source checkout in place.

Install the plugins for each client you use, from the same main checkout:

```bash
# Codex
codex plugin marketplace add "$PWD/agent/elixir-agent-tools"
codex plugin add mix-compile@elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code (user scope makes the installations available across worktrees)
claude plugin marketplace add "$PWD/agent/elixir-agent-tools"
claude plugin install --scope user elixir-dev@elixir-agent-tools
claude plugin install --scope user mix-compile@elixir-agent-tools
claude plugin install --scope user mix-credo@elixir-agent-tools
```

Codex discovers the linked `.agents/skills`; do not also install `elixir-dev` for
Codex. Claude loads the same five skills through the `elixir-dev` plugin, using
its native plugin discovery. The generated client configs enable the two Mix
check plugins. Follow each client's plugin trust prompts during setup.
Tips uses its own patched LSP bridge; the generated Claude config disables the
upstream `elixir-lsp` plugin.

Build the shared Expert and MCP bridge binaries using the
[LSP setup guide](../lsp/README.md#build-and-validate), then start new client sessions.

## Start and assign

Complete [one-time setup](#one-time-setup) first. Run the commands below in a Herdr
terminal, where `HERDR_ENV=1` is set by Herdr.

Handle each client's repository trust prompt during initial setup. An unexpected approval prompt stops launch; inspect it and follow the active approval policy. The launcher does not edit home-directory trust settings.

Run lifecycle commands from the main checkout. It remains read-only for source changes. Use one lifecycle caller per team.

```bash
agent/teams/team.py start N
```

This creates/reuses the team's workspace and four named panes, starts/briefs its TPM and prints pane IDs. Coding panes stay at the shell until assigned. `agent/teams/team.py start lead` provides the same configured launch for a new lead TPM; do not run it if another live agent already owns `lead-tpm`.

The lead TPM reads relevant issue/PR evidence on each message, picks an unblocked issue on the critical path and sends its URL to the team TPM. No file reservation list or merge slot is required. The team TPM refines readiness on the issue and starts the tech lead at a captured base SHA to confirm it. After readiness, it posts the self-contained dispatch and adds `active`.

Use the existing issue's task slug; do not generate a new branch when its title changes. Obtain pane IDs from the start output or `herdr pane list`; never guess them. Examples (`TASK` is `<issue>-<slug>`, `SHA` is the exact fetched revision being dispatched):

```bash
agent/teams/task_worktree.py "$TASK" --team "$N" --role dev --pane "$DEV_PANE" --start
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA" --start
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead --pane "$LEAD_PANE" --review-ref "$SHA" --start
```

The helper provisions skills and only the chosen client's local config, applies environment in the target pane and starts the real interactive client. `--kind` is optional and must match the role's configured kind. Inspect config conflicts before explicitly replacing generated files with `--force`. Repeated calls reuse an already matching live session. Conflicting assignments fail. Reviewer advances require clean source even at the same SHA and verified old-client shutdown before a different SHA. Fresh reviewer sessions carry history through PR comments.

Brief immediately after successful client launch; do not wait for project compilation. Send the issue/PR contract link, base/head SHA, requested action and owner. Put outcome/exclusions, exact reading and acceptance/verification in that linked contract instead of repeating them. Follow [Context and handoff](#context-and-handoff), including the exact completion command in every dispatch. Developers implement and push; they do not switch to another issue before this one merges.

## Review and merge

**Tester:** Review every pushed commit in context, first for local correctness, then callers and related features/tests, then end-to-end behavior. Map acceptance to named tests; trust CI only for commands it ran. Independently run missing relevant checks using the assigned environment. Post the verdict and evidence on the PR and send its link and reviewed SHA to the team TPM. Send actionable findings to the developer too; a passing verdict needs no developer acknowledgment or second request for lead review. Repairs receive another verdict. Required acceptance failures block completion regardless of severity.

**Tech lead:** After tester findings are resolved, read the whole diff against the current base. Challenge implementation, architecture and assumptions with concrete alternatives and tradeoffs. Evaluate each proposed fix's downstream effects. Resolve technical disagreement using evidence; escalate material product changes through the TPM. A rejected design creates new commits that the tester reviews again.

P0 means critical exposure, irreversible loss or fundamental inability to operate. P1 means broken required behavior, authorization/consistency defects or missing evidence needed to integrate safely. P2/P3 are lower-impact defects or improvements; record follow-up issues when deferred. Do not downgrade findings merely to pass. Repeated failed repairs require root-cause analysis rather than more blind attempts.

The tech lead posts a review record with reviewer/implementer, base/head SHAs, commit verdicts, whole-PR findings, independently run checks, unresolved findings and follow-ups. Then it publishes `tips/independent-review` on that exact head, linking the record. Main requires a PR, resolved conversations, an up-to-date branch and the required `checks`, `release` and independent-review contexts. This is an interlock, not credential isolation.

Merge uses native GitHub CLI commands, without a TPM merge queue:

```bash
gh pr update-branch "$PR"
# If HEAD changed: report it to the team TPM for redispatch before continuing.
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

Capture the new head after branch update. A new head needs a new status: the tech lead reviews the base delta and publishes a new status on that SHA; conflict resolution also goes through the tester. Resume the checks/merge sequence after those verdicts arrive. A base change during this sequence can make the strict gate reject the merge; inspect the new state and repeat the necessary review. A timeout, rate limit or failed required check is not success. Record the PR, reviewed head, merge SHA and review evidence on the issue, then notify the TPM. Do not synchronously watch main or automatically revert its changes.

## Context and handoff

Every dispatch includes the exact recipient and `herdr agent prompt` command to run on completion or a blocker. "Reply to the TPM" alone is insufficient. Keep the message to an evidence link, SHA, action and owner; link the existing task contract instead of copying it.

A handoff has two steps: record durable evidence on GitHub, then execute `herdr agent prompt` to deliver its link to the team TPM. A GitHub comment or final chat response does not wake another pane. Before ending the turn, verify the Herdr command succeeded; if it failed, report the error and do not claim delivery. Use the same handoff for readiness, implementation, review, merge and blockers. For example, with the actual team number and evidence filled in:

```bash
herdr agent prompt "team-$N-tpm" "$EVIDENCE_URL SHA=$SHA; action=assess tester dispatch; owner=team-$N-tpm"
```

The TPM assesses the evidence and dispatches the next role. After a tester pass, the developer does not send another request for lead review. Team TPMs send completion or outside blockers to `lead-tpm` using the same direct command. No hooks, `--wait`, polling or waiting on agent replies. A single bounded foreground wait for known CI checks is allowed.

Run lifecycle and messaging commands directly. Keep their stdout, stderr and exit status; do not pipe them through `tail` or ad hoc JSON formatters. Parse Herdr JSON only when a subsequent operation needs a returned ID or field, under `result`. A failed formatter is not evidence that a message was undelivered: inspect once before resending. A successful send confirms submission, not task completion.

For a permission blocker, preserve the work and report the failed operation, exact error and local state to the team TPM for authorized recovery. Do not route around the denial through another application or a remote-only commit. The TPM owns the next workflow decision; the worker retains checkout ownership until explicitly transferred.

For context recovery, keep the issue/branch open and record base/head SHAs, working-tree cleanliness, committed/uncommitted work, unresolved findings, failed/unrun checks and the next action. Explicitly transfer ownership before starting another writer. Never reset or stash someone else's work to recover a session. Inspect Git and pane evidence before reassigning an unresponsive client. Never put credentials in logs, issues or handoffs.

## Who wakes whom

| Sender | Next recipient/action |
|---|---|
| Lead TPM | Team TPM: assign issue or resolve a cross-team/user blocker. |
| Team TPM | Tech lead: readiness; developer: implementation; reviewer: exact SHA after provisioning its session. |
| Developer | Team TPM: pushed SHA and evidence for tester dispatch, or blocker. No duplicate lead-review request after tester pass. |
| Team TPM | Tester: commit review; tech lead: complete-PR review after tester verdicts pass. |
| Tester | Team TPM: every PR verdict/evidence. Developer too when there are actionable findings. |
| Tech lead | Team TPM: readiness, review findings, changed head or merged PR with reviewed/merge SHAs. Developer too when there are actionable findings. |
| Team TPM | Lead TPM: completed issue or blocker requiring outside action. |

## Environment and cleanup

The helper applies the selected role's configured model, effort, permissions, database suffix and test port in the actual target process. Only the selected client's generated configuration is written. Both clients invoke the canonical main checkout's LSP wrapper with the assigned absolute worktree root. Review revisions do not need to contain that wrapper. Keep installed patched bridge/Expert tools available independently of task worktrees.

Startup reports **client launched**, not index ready. Brief the agent once Herdr reports it ready. Expert can keep compiling in the background. Do not add a compile gate or launch a second LSP as a probe. Configuration/tooling changes require a disposable actual-client pilot checking both the client root and LSP root for each client. The configured team limit is not a verified simultaneous cold-start capacity; measure it before scaling up.

TPMs run without the Elixir LSP. Coordinator launches use configured compaction; coding launches do not inherit that coordinator override. Codex approval policy does not change or guarantee its sandbox; it retains the user's sandbox configuration. Claude's permission mode comes from the same config.

The database connection limit is configured in [compose.yaml](../../compose.yaml), with `TIPS_DB_MAX_CONNECTIONS` as the standard Compose override. Apply it by recreating the database service only while no teams are running. Agent launch settings do not restart PostgreSQL or existing clients.

## Merge and retire

The tech lead performs the exact-SHA review/status and native merge sequence in [Review and merge](#review-and-merge). A changed head requires a new review; conflict resolution goes to the tester. The TPM removes stale labels and reports merge evidence to the lead TPM.

After merge, the lead TPM retires the team from another workspace:

```bash
agent/teams/team.py stop N
```

Cleanup verifies client/descendant exit and clean, integrated work before removing resources. On failure, inspect the printed leftovers; do not force-delete them. Start the team again when assigning its next issue. A client cannot stop itself through this command.

Shutdown refuses dirty or unmerged worktrees and drops only that team's test databases. Uncertainty or surviving descendants fail the command and preserve remaining resources. It never broadly kills BEAM processes or deletes the shared engine cache. Do not run overlapping lifecycle calls; one TPM owns a team's transitions, with no lock or daemon.

## Escalation

Mark blocked work with `blocked` and a comment naming the missing prerequisite, responsible role and next action. Escalate credentials, purchases, hosting, material product decisions and evidence-based technical disagreements through the team TPM to the lead TPM. Inspect permission dialogs and follow the active tool/user approval policy; never treat this document as permission to answer an approval prompt. Keep secrets out of GitHub and logs.

The lead TPM communicates what the user needs to decide. The user detects silent stalls. No status-file PRs, polling daemon, merge queue or own-list approval is required.

## Milestones and external prerequisites

M0 proves reproducible startup, release and testing; M1 proves risky boundaries on one revision; M2 proves the complete product; M3 rehearses operations; M4 records trial readiness and the user's public-launch decision. Each gate names its environment, revision, evidence and unresolved blockers.

The lead TPM tracks access/setup requirements for hosting, domain, providers, operator identity, vocabulary and content in GitHub issues. Agents propose defaults and use synthetic fixtures; they do not fabricate firsthand production content. Before launch, the intended VPS is the preproduction environment. Run real-provider tests only through explicitly authorized invocations with scoped secrets, never automatically on arbitrary PR code. Ordinary PR CI needs no production secrets.
