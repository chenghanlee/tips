# Goal: implement every issue in the Tips project

Every agent reads [agent-workflow.md](agent-workflow.md) and [AGENTS.md](../../AGENTS.md). Complete the issues in [Project 15](https://github.com/users/chenghanlee/projects/15), including new child issues, until everything is done or blocked on the user. GitHub carries state and evidence.

## Configuration

Edit [config/agent-team.toml](../../config/agent-team.toml) to change team limits, client/model/effort by role, port/database allocation, permission modes, coordinator compaction and time budgets. Scripts read the canonical main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged configuration for a disposable pilot. Settings take effect on the next launch. The patched bridge has a compiled request deadline; changing its corresponding client timeout requires rebuilding and retesting the bridge too.

The generated Codex config applies `launch.codex_lsp_approval_mode` only to the four enabled LSP tools. It leaves the overall approval and sandbox policies in place. This uses the [supported per-tool MCP setting](https://developers.openai.com/codex/mcp); `never` otherwise rejects a tool that requires approval.

Database suffixes combine `team.db_suffix_prefix`, the team number and `roles.<role>.db_suffix`. Test ports combine `team.port_base`, team number times `team.port_stride`, and the role's `port_offset`. The launcher exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV` and `TIPS_CHECK_TIMEOUT_SECONDS` directly to the coding process. Leave those computed resources in place for tests, including Wallaby.

## Start and assign

Handle each client's repository trust prompt during initial setup. In the tested client pair, trust in the canonical repository carried over to new sibling worktrees. An unexpected approval prompt stops launch; inspect it and follow the active approval policy. The launcher does not edit home-directory trust settings.

Run lifecycle commands from the main checkout. It remains read-only for source changes. Use one lifecycle caller per team.

```bash
scripts/team.py start N
```

This creates/reuses the team's workspace and four named panes, starts/briefs its TPM and prints pane IDs. Coding panes stay at the shell until assigned. `scripts/team.py start lead` provides the same configured launch for a new lead TPM; do not run it if another live agent already owns `lead-tpm`.

The lead TPM reads relevant issue/PR evidence on each message, picks an unblocked issue on the critical path and sends its URL to the team TPM. No file reservation list or merge slot is required. The team TPM refines readiness on the issue and starts the tech lead at a captured base SHA to confirm it. After readiness, it posts the self-contained dispatch and adds `active`.

Use the existing issue's task slug; do not generate a new branch when its title changes. Obtain pane IDs from the start output or `herdr pane list`; never guess them. Examples (`TASK` is `<issue>-<slug>`, `SHA` is the exact fetched revision being dispatched):

```bash
scripts/task_worktree.py "$TASK" --team "$N" --role dev --pane "$DEV_PANE" --start
scripts/task_worktree.py "$ISSUE-review-team-$N-test" --team "$N" --role test --pane "$TEST_PANE" --review-ref "$SHA" --start
scripts/task_worktree.py "$ISSUE-review-team-$N-lead" --team "$N" --role lead --pane "$LEAD_PANE" --review-ref "$SHA" --start
```

The helper provisions skills and only the chosen client's local config, applies environment in the target pane and starts the real interactive client. `--kind` is optional and must match the role's configured kind. Inspect config conflicts before explicitly replacing generated files with `--force`. Repeated calls reuse an already matching live session. Conflicting assignments fail. Reviewer advances require clean source even at the same SHA and verified old-client shutdown before a different SHA. Fresh reviewer sessions carry history through PR comments.

Brief immediately after successful client launch; do not wait for project compilation. Dispatch includes issue/PR link, base/head SHA, outcome/exclusions, exact reading, acceptance/verification and reply-to name. Developers implement and push; they do not switch to another issue before this one merges.

## Who wakes whom

Use plain messages: **link, SHA, request, reply-to**. No event vocabulary or message protocol is needed.

| Sender | Next recipient/action |
|---|---|
| Lead TPM | Team TPM: assign issue or resolve a cross-team/user blocker. |
| Team TPM | Tech lead: readiness; developer: implementation; reviewer: exact SHA after provisioning its session. |
| Developer | Team TPM: pushed SHA needing tester dispatch; PR ready for final review. |
| Team TPM | Tester: commit review; tech lead: complete-PR review after tester verdicts pass. |
| Tester | Developer and team TPM: PR verdict/evidence; developer repairs findings. |
| Tech lead | Developer and team TPM: design findings, or merged PR with reviewed/merge SHAs. |
| Team TPM | Lead TPM: completed issue or blocker requiring outside action. |

TPMs handle dispatch and session changes; technical leads retain uninterrupted time for deep PR review. After waking the next role, end the turn. Never poll or wait on another agent. For CI, use the bounded `gh pr checks` command in the workflow. A failed launch or check is a failure to report, not a reason to claim progress.

## Merge and retire

The tech lead performs the exact-SHA review/status and native merge sequence in [agent-workflow.md](agent-workflow.md#review-and-merge). A changed head requires a new review; conflict resolution goes to the tester. The TPM removes stale labels and reports merge evidence to the lead TPM.

After merge, the lead TPM retires the team from another workspace:

```bash
scripts/team.py stop N
```

Cleanup verifies client/descendant exit and clean, integrated work before removing resources. On failure, inspect the printed leftovers; do not force-delete them. Start the team again when assigning its next issue. A client cannot stop itself through this command.

## Escalation

Mark blocked work with `blocked` and a comment naming the missing prerequisite, responsible role and next action. Escalate credentials, purchases, hosting, material product decisions and evidence-based technical disagreements through the team TPM to the lead TPM. Inspect permission dialogs and follow the active tool/user approval policy; never treat this document as permission to answer an approval prompt. Keep secrets out of GitHub and logs.

The lead TPM communicates what the user needs to decide. The user detects silent stalls. No status-file PRs, polling daemon, merge queue or own-list approval is required.
