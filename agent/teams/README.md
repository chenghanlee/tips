# Agent teams

Run the commands below from the repository root. This directory contains the team
launchers and configuration; `tests/` contains their integration tests. Shared
Elixir LSP tooling lives in `agent/lsp/`; see the
[LSP build and acceptance guide](../lsp/README.md).

This is the operating agreement for building Tips. [AGENTS.md](../../AGENTS.md) governs engineering. GitHub issues and PRs hold requirements, decisions, review history and evidence. [team configuration](config.toml) owns agent settings; do not duplicate its defaults in commands or prose.

The lead TPM coordinates assigned work in [Project 15](https://github.com/users/chenghanlee/projects/15), including child issues. Work continues within the user's assigned scope until completed or blocked on the user.

## Check changes to these scripts

Developers run these four commands in their task worktree before pushing, with
Python 3.12 and the installed Ruff and Pyright tools:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

The required `checks` job runs the same four commands. Reviewers (tester and tech
lead, Codex or Claude) do not rerun them locally: they open the `checks` run for the
exact reviewed head, confirm each of these steps ran and passed, and link that run
in their record.

[Python check settings](pyproject.toml) follow the harness's Python profile: strict
types, a complexity limit of 10, and the same lint rules. The test assertion
exception applies only to Python files under `tests/`.
The scripts and tests use only the standard library.

Tests use disposable Git repositories, a fake Herdr CLI, and owned child processes.
They do not operate live teams. Process tests require permission to run `ps` and
signal their own children.

Two reviewed S603 exceptions carry inline `# noqa: S603`: the shared command
runner `team.py:execute` and the process-test launcher `StopAgentTest.client`.
Both accept variable argument lists but run without a shell, on a resolved
executable with fixed or test-owned arguments. Suppress nothing else. Review any
change to these calls for trusted executable selection and argument handling; the
passing lint does not prove subprocess safety.

## Roles

One lead TPM assigns work to teams within the configured trial limit. Each team handles one issue at a time. Inside a team the tech lead runs the engineering and the TPM runs project state, the way a real team works.

| Role | Owns |
|---|---|
| Lead TPM (`lead-tpm`) | Assign issues, start/retire teams, resolve cross-team blockers, relay owner prerequisites and owner decisions, report to the user. Talks only to team TPMs and the user. Runs lifecycle commands under the same output rule as team TPMs. "Agree, proceed" is final: a change of mind becomes a follow-up issue, never a hold on a merge already authorized. |
| Team TPM (`team-N-tpm`) | Labels, Project fields, team start, the tech lead's launch and every worktree provisioning the tech lead requests; cross-team and user blockers. Talks only to its tech lead and the lead TPM. |
| Tech lead (`team-N-lead`) | Confirm readiness; decide when the developer and tester are provisioned; brief and advance them; decide technical disputes; review the whole PR; publish its review status and merge. Persistent for one issue. |
| Developer (`team-N-dev`) | Implement the issue with integration-first TDD; own its branch, worktree and PR. |
| Tester (`team-N-test`) | Independently review each pushed commit and run relevant verification. One session per issue, advanced in place to each reviewed SHA. |

A role receives only duties its configured launch policy can execute. Main-checkout Git administration (branches, worktrees, fetches) belongs to the team TPM: the tech lead decides what to provision and when, and the TPM executes it. A Codex lead's sandbox cannot write main's `.git`; Claude leads follow the same flow.

Developer, tester and tech lead message each other freely. The tech lead dispatches and advances review stages; the TPM does not talk to the developer or tester, except as the fallback when a message to the lead fails to send (see [Escalation](#escalation)). The tech lead and the tester stay for the whole issue and are restarted by the TPM at the next assignment. The tester reviews the first head in full and each repair delta after that; the tech lead's whole-PR review is the full read of the final diff. A fresh tester starts only when its session is lost or the tech lead rejects the design. Tech leads of different teams coordinate directly and tell their TPM only when it changes sequencing, ownership or creates a blocker. Nobody reviews or merges their own implementation. The tester may ask the developer anything, but its verdict cites code, tests and evidence, never the developer's explanation. The common GitHub identity cannot mechanically prove reviewer independence.

Tie-breakers: the tech lead decides technical disputes. Scope or product questions go tech lead → team TPM → lead TPM → user.

Issues labelled `ui` (frontend UI/UX design and implementation) get the `roles.lead_ui` tech lead, launched with `--ui`; all other issues get `roles.lead`. Developer and tester settings do not change.

Issues labelled `probe` deliver evidence, not a code path: the lead TPM sets the label at Ready, the tester passes once, and the review record keeps its five headings at one line each. Probe code is disposable; do not spend repair rounds on it beyond what the evidence needs.

The user decides material product changes, purchases, credentials, hosting and public launch. Routine technical choices belong to the responsible role. No budget has been fixed; absence of a ceiling does not authorize purchases.

## Configuration

Edit [agent/teams/config.toml](config.toml) to change team limits, client/model/effort by role, port/database allocation, permission modes, coordinator compaction and time budgets. Scripts read the canonical main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged configuration for a disposable pilot. Settings take effect on the next launch. The patched bridge has a compiled request deadline; changing its corresponding client timeout requires rebuilding and retesting the bridge too.

The generated Codex config applies `launch.codex_lsp_approval_mode` only to the four enabled LSP tools. It leaves the overall approval and sandbox policies in place. This uses the [supported per-tool MCP setting](https://developers.openai.com/codex/mcp); `never` otherwise rejects a tool that requires approval.

Database suffixes combine `team.db_suffix_prefix`, the team number and `roles.<role>.db_suffix`. Test ports combine `team.port_base`, team number times `team.port_stride`, and the role's `port_offset`. The launcher exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV` and `TIPS_CHECK_TIMEOUT_SECONDS` directly to the coding process. Leave those computed resources in place for tests, including Wallaby. To check them from a client's shell tool, run `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable.

## Task readiness

The lead TPM picks critical-path issues whose prerequisites are integrated and evidenced, preferring the team's current package. Package parent issues are not coding assignments. One issue is one PR that merges on its own with one outcome. Split before Ready when the contract has a second independent outcome or when the tech lead's context would not last to the merge; there is no numeric cap.

Before dispatch, the tech lead records one outcome, exclusions, exact design sections and real entry points, acceptance scenarios, runnable verification and available prerequisites on the issue, amending the technical contract when necessary. The readiness comment ends with one line, `Needs from owner:` followed by `none` or the secrets, credentials and network access the task requires; nothing else belongs on it. The team TPM relays that line to the lead TPM, who forwards it to the user and dispatches without waiting. The team does the work that does not depend on it first. Discovery may be its own task. Do not require file ownership lists, reservations or overlap approval; coordinate concrete shared changes when they arise.

Each coding issue records acceptance-to-test mappings. Milestone gates require E2E evidence on one integrated revision; isolated task reports do not establish a gate. Closing a package requires its mandatory children and package acceptance evidence.

## Issue and project state

Use GitHub issues and PRs as the source of truth. Add `active` when assigned; add `blocked` when progress requires outside action, with the prerequisite, responsible role and next action in a comment. Remove stale labels as the situation changes. A waiting dependency is not automatically a user blocker. Do not mirror a workflow state machine into Project fields or maintain a separate status document.

An issue closes only when its required result is integrated and evidenced. Partial work uses `Refs #number`; a completing PR uses `Closes #number`. Child issues created during the run count toward the goal.

## Git

Use protected `main`, short-lived `task/<issue>-<slug>` branches and worktrees under `.worktrees/`. While any team is live, the main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there, because running clients and the lifecycle scripts are rooted at it. Repository administration such as fetch and worktree creation runs from main, by the team TPM (or the lead TPM for `team.py stop`). Make every source change in a worktree, including documentation and operational scripts.

When no team is live, the user or the lead TPM may branch directly in the main checkout and return it to `main` once the PR merges. A PR that changes only documentation needs no local test run; the required CI checks still run on it.

The team TPM runs `agent/teams/task_worktree.py` for every role: the tech lead at assignment, and the developer, tester and lead advances on the tech lead's request. Keep the existing task slug when an issue is renamed. The developer owns its task worktree; tester and tech lead have separate detached review worktrees. No agent edits another's checkout. The helper checks reviewer cleanliness even at the same SHA, checks selected-client configuration before changing HEAD, reuses a matching live session, and advances a running reviewer's clean detached checkout in place. Only an explicit `--start` on a running tester at a new SHA stops the old client and verifies descendant exit before launching a fresh one. `/new`, `/clear` and `cd` inside an already-running client do not reroot its LSP.

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

The lead TPM reads relevant issue/PR evidence on each message, picks an unblocked issue on the critical path and sends its URL to the team TPM. No file reservation list or merge slot is required. The team TPM adds `active` and starts the tech lead at a captured base SHA, with `--ui` when the issue carries the `ui` label. The tech lead confirms readiness on the issue, then has the TPM provision the developer, and later the tester at the first pushed SHA, and briefs each one. The TPM advances the tester and the tech lead to each later SHA in place.

Use the existing issue's task slug; do not generate a new branch when its title changes. Obtain pane IDs from the start output or `herdr pane list`; never guess them.

The TPM runs every provisioning command from the main checkout. Codex and Claude leads use the same flow:

1. Tech lead → TPM: one line with role, pane and exact SHA.
2. TPM runs the matching command below.
3. TPM → tech lead: pane, absolute worktree and actual SHA.
4. Tech lead confirms that pane, worktree and SHA inside the new client (`herdr agent get`, `git -C "$WORKTREE" rev-parse HEAD`) before briefing.

The helper and `team.py stop` check that they can write main's `.git` before fetching; a caller that cannot, such as a sandboxed lead, is refused with the TPM to ask instead. Examples (`TASK` is `<issue>-<slug>`, `SHA` is the exact fetched revision being dispatched):

```bash
# At assignment (add --ui for an issue labelled ui):
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA" --start
# On the tech lead's request:
agent/teams/task_worktree.py "$TASK" --team "$N" --role dev --pane "$DEV_PANE" --start
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA" --start
# Later SHAs: advance the running reviewers in place (no --start).
agent/teams/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA"
agent/teams/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead [--ui] --pane "$LEAD_PANE" --review-ref "$SHA"
```

Repeat `--ui` on every later call for a UI lead; without it the helper resolves the other lead configuration and refuses the running client as a conflict.

The helper provisions skills and only the chosen client's local config, applies environment in the target pane and starts the real interactive client. That environment includes `TIPS_PROVIDER_ENV_FILE`, the main checkout's `.env`, for every role, so provider settings are read by path and no secret is ever written into a worktree. `--kind` is optional and must match the role's configured kind. Inspect config conflicts before explicitly replacing generated files with `--force`. Repeated calls reuse an already matching live session. Conflicting assignments fail. A running reviewer is not stopped for a new SHA: without `--start`, the helper moves its clean, detached, read-only checkout in place, and its LSP keeps the same root. `--start` with a new SHA on a running tester stops it, verifies descendant exit and launches a fresh session; use it only for a lost session or a rejected design. A running tech lead always advances in place.

Brief immediately after confirming the launched client; do not wait for project compilation. Send the issue/PR contract link, base/head SHA, requested action and owner. Put outcome/exclusions, exact reading and acceptance/verification in that linked contract instead of repeating them. Follow [Context and handoff](#context-and-handoff), including the exact completion command in every dispatch. Developers implement and push; they do not switch to another issue before this one merges.

**Developer owns green.** Before each commit, read the checks result of the previous push. Keep working locally while it runs; push only once that result is in, and never onto a head whose red you have not repaired. Name any change to check configuration (ignore files, workflow, lint or scanner settings) in your round so the tech lead reviews it explicitly. Red caused by `main` is reported, not repaired.

## Review and merge

**One comment per role.** The developer, the tester and the tech lead each keep one PR comment and edit it in place, adding a `## <short SHA> <outcome>` round per reviewed head, newest last, with `###` headings inside a round. A handoff links that comment and names the SHA. No new comment per round.

**Tester:** A red head is not reviewed: send one Herdr message to the developer and the tech lead naming the failing check, and add a two-line `## <short SHA> RED` round to the tester comment. Otherwise review the first pushed head in full, then each repair delta, first for local correctness, then callers and related features/tests, then end-to-end behavior. Map acceptance to named tests; trust CI only for commands it ran. Independently run missing relevant checks using the assigned environment; `agent/teams` Python checks come from CI, not a local rerun. Add the verdict and evidence to the tester comment and send its link and reviewed SHA to the tech lead. Send actionable findings to the developer too; a passing verdict needs no developer acknowledgment. Repairs receive another verdict. Required acceptance failures block completion regardless of severity.

**Tech lead:** After the tester passes the last repair, run `gh pr update-branch "$PR"` and take the resulting head. Read the whole diff of that integrated head against `main` and run the full check suite once on it, except the `agent/teams` Python checks, which reviewers read from the exact-head `checks` run (see [Check changes to these scripts](#check-changes-to-these-scripts)). Write the review record as the `## <short SHA>` round for that head in the lead comment, with these five `###` headings, spelled exactly, each with substance:

1. `### Local correctness` — the changed functions and modules on their own.
2. `### Downstream effects` — callers, related modules, features and tests the change touches.
3. `### Whole-project fit` — the change against the project's design, architecture and end-to-end behavior.
4. `### Design challenge` — the chosen implementation questioned against concrete alternatives, with tradeoffs and the assumptions it rests on.
5. `### Defect pass` — a stricter hunt for implementation defects than the per-commit reviews, on the integrated diff.

Resolve technical disagreement using evidence; escalate material product changes through the TPM. A rejected design creates new commits that the tester reviews again.

P0 means critical exposure, irreversible loss or fundamental inability to operate. P1 means broken required behavior, authorization/consistency defects or missing evidence needed to integrate safely. P2/P3 are lower-impact defects or improvements; record follow-up issues when deferred. Do not downgrade findings merely to pass. Repeated failed repairs require root-cause analysis rather than more blind attempts.

The record also names reviewer/implementer, base/head SHAs, commit verdicts, independently run checks, unresolved findings and follow-ups. Then the tech lead publishes `tips/independent-review` on that exact head through the script, which reads only the round whose `##` heading starts with that SHA and refuses when that round is missing or duplicated, when a heading in it is missing or empty, or when the PR head has moved:

```bash
agent/teams/publish_review.py --pr "$PR" --sha "$REVIEWED_SHA" --record "$RECORD_COMMENT_URL"
```

Main requires a PR, resolved conversations, an up-to-date branch and the required `checks`, `release` and independent-review contexts. This is an interlock, not credential isolation. The approving review is the closing record; decisions made in chat that are not already in PR threads go in its body. No separate closing note.

**Owner waiver.** When no team is live and the change is owner-driven, the user may skip the independent review. Only on the user's explicit instruction in the session, the user or the lead TPM runs `publish_review.py --owner-waiver "<reason>"` instead of `--record`; it posts a waiver comment with the reason on the PR and publishes the status pointing at it. The waiver is the audit trail. Agents never invoke it on their own, and it does not waive the CI checks.

**Hotfix review.** A waived change that touches code still gets a Codex review before merge, through the ad-hoc channel below. Documentation-only changes need none.

**Ad-hoc Codex reviewer.** A Codex reviewer outside a team cannot post to GitHub. Before launching it, the lead TPM creates `tmp/review-<issue>/chavruta.md` (ignored by Git) and names that path in the prompt; both sides append rounds there until they agree, and the lead TPM posts the outcome on the PR. Nothing under `tmp/` enters the repository. Pilot agents in a disposable team are under the same policy: the tech lead that runs the pilot posts their evidence.

**No machine-level installs without the owner's explicit approval.** No agent installs packages, tools or software on the machine or changes machine, sandbox or client configuration: `brew`, casks, `pip`/`uv tool`, `npm -g`, system or client settings, Docker images outside the compose file. Project dependencies declared in the repository go through the PR as any other change. When a task truly needs one, mark the issue `blocked` with the exact command and continue unaffected work; the lead TPM asks the user, quotes the answer in an issue comment, and the agent proceeds only from that link. Checks that must run for every PR belong in CI, not in a reviewer's local environment.

Merge uses native GitHub CLI commands, without a TPM merge queue:

```bash
gh pr update-branch "$PR"   # "already up to date" is not an error
REVIEWED_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
# Whole-PR review and publish_review.py on REVIEWED_SHA, then:
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

The branch update comes first so the one whole-PR review covers the integrated head; required CI runs on that head, so no local re-run and no tester round follow a clean update. If the update conflicts, the developer resolves it, the tester reviews the resolution, and the sequence restarts. If `main` moves again before merge, the strict gate rejects the merge: update again, review the base delta, publish a new status on the new head. A timeout, rate limit or failed required check is not success. The timed `gh pr checks --watch` above is the one allowed foreground wait, tech lead only. Record the PR, reviewed head, merge SHA and review evidence on the issue, then notify the TPM. Do not synchronously watch main or automatically revert its changes.

## Context and handoff

Every dispatch includes the exact recipient and `herdr agent prompt` command to run on completion or a blocker. "Reply to the lead" alone is insufficient. A handoff is one line: evidence link, SHA, action and owner; link the existing task contract instead of copying it. Questions between developer, tester and tech lead may be freeform. A question about code carries a pushed SHA so the reader looks at the real state in its own worktree.

A handoff has two steps: record durable evidence on GitHub, then execute `herdr agent prompt` to deliver its link to the tech lead. A GitHub comment or final chat response does not wake another pane. Before ending the turn, verify the Herdr command succeeded; if it failed, report the error and do not claim delivery. Use the same handoff for readiness, implementation, review, merge and blockers. For example, with the actual team number and evidence filled in:

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

Waiting is event-driven: Herdr is the event bus. An agent that needs an answer sends the prompt, finishes any work that does not depend on the answer, and ends its turn; the reply arrives as a new prompt in its pane. No `sleep`, polling loop, monitor, cron, hook or `--wait`. The one exception is the tech lead's timed CI wait before merge.

Decisions are durable only on GitHub. Whoever decides posts it on the issue or PR before the next step: the tech lead for engineering and implementation decisions, the TPM for project decisions. The asker links that post in its next handoff. Besides provisioning requests, the tech lead reports to the TPM only what changes a label, a Project field or a blocker: readiness confirmed, dispatched, PR opened, verdicts, merged, blocked, scope question. The TPM reads GitHub on every wake; a message is a wake signal, not the record. Team TPMs send completion or outside blockers to `lead-tpm` using the same direct command.

Run lifecycle and messaging commands directly. Keep their stdout, stderr and exit status; do not pipe them through `tail` or ad hoc JSON formatters. Parse Herdr JSON only when a subsequent operation needs a returned ID or field, under `result`. A failed formatter is not evidence that a message was undelivered: inspect once before resending. A successful send confirms submission, not task completion.

For a permission blocker, preserve the work and report the failed operation, exact error and local state to the tech lead for authorized recovery; the tech lead escalates to the TPM when the recovery needs the user. Do not route around the denial through another application or a remote-only commit. The tech lead owns the next workflow decision; the worker retains checkout ownership until explicitly transferred.

For context recovery, keep the issue/branch open and record base/head SHAs, working-tree cleanliness, committed/uncommitted work, unresolved findings, failed/unrun checks and the next action. Explicitly transfer ownership before starting another writer. Never reset or stash someone else's work to recover a session. Inspect Git and pane evidence before reassigning an unresponsive client. Never put credentials in logs, issues or handoffs.

## Who wakes whom

| Sender | Next recipient/action |
|---|---|
| Lead TPM | Team TPM: assign issue or resolve a cross-team/user blocker. |
| Team TPM | Tech lead: issue URL and base SHA at assignment; pane, worktree and SHA after each provisioning; answers to scope questions; restart after silence. |
| Tech lead | Developer: dispatch, answers, review findings. Tester: exact SHA after the TPM provisions or advances its session. Team TPM: provision and advance requests with role, pane and SHA; state changes and blockers. Another team's tech lead: shared-module coordination. |
| Developer | Tech lead: pushed SHA and evidence for tester dispatch, questions, or blocker. Tester: answers to its questions. |
| Tester | Tech lead: every PR verdict/evidence. Developer: actionable findings and questions. |
| Team TPM | Lead TPM: completed issue or blocker requiring outside action. |

## Environment and cleanup

The helper applies the selected role's configured model, effort, permissions, database suffix and test port in the actual target process. Only the selected client's generated configuration is written. Both clients invoke the canonical main checkout's LSP wrapper with the assigned absolute worktree root. Review revisions do not need to contain that wrapper. Keep installed patched bridge/Expert tools available independently of task worktrees.

Startup reports **client launched**, not index ready. Brief the agent once Herdr reports it ready. Expert can keep compiling in the background. Do not add a compile gate or launch a second LSP as a probe. Configuration/tooling changes require a disposable actual-client pilot checking both the client root and LSP root for each client. The configured team limit is not a verified simultaneous cold-start capacity; measure it before scaling up.

TPMs run without the Elixir LSP. Coordinator launches use configured compaction; coding launches do not inherit that coordinator override. Codex approval policy does not change or guarantee its sandbox; it retains the user's sandbox configuration. Claude's permission mode comes from the same config.

The database connection limit is configured in [compose.yaml](../../compose.yaml), with `TIPS_DB_MAX_CONNECTIONS` as the standard Compose override. Apply it by recreating the database service only while no teams are running. Agent launch settings do not restart PostgreSQL or existing clients.

## Merge and retire

The tech lead performs the branch update, exact-SHA review/status and native merge sequence in [Review and merge](#review-and-merge). A head that changes after the review requires a new review; conflict resolution goes to the tester. The TPM removes stale labels and reports merge evidence to the lead TPM.

After merge, the lead TPM retires the team from another workspace:

```bash
agent/teams/team.py stop N
```

Cleanup verifies client/descendant exit and clean, integrated work before removing resources. On failure, inspect the printed leftovers; do not force-delete them. Start the team again when assigning its next issue. A client cannot stop itself through this command.

Shutdown refuses dirty or unmerged worktrees and drops only that team's test databases. Uncertainty or surviving descendants fail the command and preserve remaining resources. It never broadly kills BEAM processes or deletes the shared engine cache. Do not run overlapping lifecycle calls; one TPM owns a team's transitions, with no lock or daemon.

## Escalation

Mark blocked work with `blocked` and a comment naming the missing prerequisite, responsible role and next action. Inside a team the tech lead decides technical disputes. Credentials, purchases, hosting, material product decisions and cross-team blockers or disagreements go tech lead → team TPM → lead TPM. Inspect permission dialogs and follow the active tool/user approval policy; never treat this document as permission to answer an approval prompt. Keep secrets out of GitHub and logs.

If a developer's or tester's `herdr agent prompt` to the tech lead fails to send, send the same message to the team TPM, who restarts or replaces the lead. If the send succeeded but the work is blocked on an unanswered question, add the `blocked` label with a comment naming the tech lead and the question, then end the turn; the TPM sees the stall on its next wake and restarts the lead.

The lead TPM communicates what the user needs to decide. The user detects silent stalls. No status-file PRs, polling daemon, merge queue or own-list approval is required.

## Milestones and external prerequisites

Milestones, their gate issues and the dev-adapter policy live in the [Project 15 readme](https://github.com/users/chenghanlee/projects/15); read it with `gh project view 15 --owner chenghanlee` before picking work, since it is not mirrored in this repository. Each gate names its environment, revision, evidence and unresolved blockers.

The lead TPM tracks access/setup requirements for hosting, domain, providers, operator identity, vocabulary and content in GitHub issues. Agents propose defaults and use synthetic fixtures; they do not fabricate firsthand production content. Before launch, the intended VPS is the preproduction environment. Run real-provider tests only through explicitly authorized invocations with scoped secrets, never automatically on arbitrary PR code. Ordinary PR CI needs no production secrets.
