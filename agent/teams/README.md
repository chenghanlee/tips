# Agent teams

Read this agreement, then your role card. [AGENTS.md](../../AGENTS.md) governs engineering. Read the issue and readiness comment for the task; they do not override this workflow. Take conflicting requirements to the next role up (see Events).

Keep task requirements, decisions and evidence in GitHub issues/PRs. Run commands from the repository root. Use [config.toml](config.toml) defaults without copying them into commands or prose. Humans perform [setup](SETUP.md) once. For script changes, read [development](development.md#changing-agentteams-scripts).

Team flow: lead TPM assigns and provisions → tech lead briefs → developer pushes → tester reviews → tech lead merges → lead TPM retires. Required feedback returns to developer for repair and another tester review. Role cards define gates and exceptions.

| Role card | Agent name | Helper flag |
|---|---|---|
| [Lead TPM](roles/lead-tpm.md) | `lead-tpm` | n/a |
| [Tech lead](roles/tech-lead.md) | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| [Developer](roles/developer.md) | `team-N-dev` | `--role dev` |
| [Tester](roles/tester.md) | `team-N-test` | `--role test` |

## Hard limits

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets. Users decide secret rotation; never rewrite history.

**Installs.** Agents never install packages, tools or software or change machine, sandbox or client configuration: `brew`, casks, `pip`, `uv tool`, `npm -g`, system or client settings, Docker images outside compose. Only the user installs, after explicit approval. Repository-declared dependencies go through PRs. For a necessary install:

1. Tech lead asks lead TPM to add `blocked` with the exact command; team continues unaffected work.
2. Lead TPM asks user and quotes the answer on the issue.
3. User runs the install; agent proceeds only from the quoted-answer link.

**Independence.** Never review or merge your own implementation. Testers may question developers, but the verdict cites code, tests and evidence, never developer explanations, because the shared GitHub identity cannot mechanically prove independence. Tech leads settle technical disputes with evidence. Route scope/product questions through tech lead → lead TPM → user. Responsible roles decide routine technical choices. Assign only duties the role's configured launch policy can execute. With no live teams, only explicit user instruction permits the [owner-waiver procedure](roles/lead-tpm.md#merge); CI remains required.

## Events

Use the reported event to find your card section; Assigned is only the first brief or provisioning request. After context recovery, reread this agreement, Always and your current card section. Reload required references missing from context before acting. `n/a`: this event cannot reach your role. "Not defined": post the question on the issue and prompt the next role up: developer/tester → tech lead → lead TPM → user.

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives.
3. **Pushed head**: review-ready PR SHA; the tester reads the first head fully, later heads as deltas.
4. **Red check**: required check failed; pending is not red.
5. **Verdict**: tester or tech lead review submitted.
6. **Merge**: PR ready to integrate, or merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: tool or client refused an action.
9. **Lost session or environment**: client, worktree or launch environment missing or wrong.
10. **Silence**: message unanswered or failed to send.
11. **Retire**: issue merged; team resources released.

## Shared rules

**Environment.** The helper sets the role's configured model, effort, permissions, database suffix and test port at launch. Rerunning it reuses the client, root and environment; wrong values are repaired only by exit and relaunch.

It exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS` and `TIPS_PROVIDER_ENV_FILE`. Codex also gets `HEX_HOME` at its worktree's ignored `tmp/hex`: its sandbox cannot write the shared Hex cache. Preserve these values in tests, including Wallaby. Inspect launch values with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable.

Provisioning links main checkout's `.agents/skills` into each worktree, fetches locked dependencies, warms Dexter and exports worktree-bound `TIPS_DEXTER`. Both clients run Dexter from the shell. Startup does not prove index freshness; see the [LSP guide](../lsp/README.md). Both clients keep the Credo hook enabled; Dexter gives no compiler diagnostics, so run explicit Mix checks after edits.

Read provider settings by path from main checkout's `.env`. Only the user adds credentials; never write secrets into worktrees. Propose defaults and use synthetic fixtures, never fabricated firsthand production content. Real-provider tests require user-authorized invocations quoted on the issue by lead TPM and scoped secrets. Never run them automatically on PR code.

**Handoff.** Every handoff sender:

1. Record evidence on GitHub.
2. Send one line via `herdr agent prompt`: evidence link, SHA, action, owner (next acting role). Link the existing contract instead of copying it. Prompt recipients separately.
3. Before ending the turn, verify the Herdr command succeeded. On failure, report the error; never claim delivery.

Use handoffs for readiness, implementation, review, merge and blockers; GitHub comments and final responses wake nobody. Dispatches name the exact recipient and completion/blocker command. Provisioning requests/replies and team questions are messages, not handoffs. Code questions include a pushed SHA for inspection in the recipient's own worktree.

Example: substitute team number and evidence.

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** After sending via Herdr, finish independent work and end the turn. Replies arrive as new prompts. Never use `sleep`, polling loops, monitors, cron, hooks, `herdr agent prompt --wait` or `herdr agent wait`; only the tech lead's timed pre-merge CI wait is exempt. No status-file PRs, merge queue, polling daemon or own-list approval.

**Decisions.** Before proceeding, tech leads record engineering decisions; lead TPM records project-state decisions. Use an issue or PR for the decision record; keep lasting design and API constraints in their canonical repository documents. Askers link the decision in their next handoff. The approving review closes the record; include chat decisions absent from PR threads in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly; retain stdout, stderr and exit status. Never pipe through `tail` or ad hoc JSON formatters. Parse Herdr's JSON output only when a later step needs a field under `result`. After formatter failure, inspect once with `herdr agent get <name>` before resending: failed formatting does not prove failed delivery. Successful sends confirm submission, not completion. Verify checkouts with `pwd` and `git rev-parse HEAD`.

**Git.** Every agent:

- Use short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; retain slugs across title changes.
- While any team is live, keep the main checkout read-only for source changes: never switch its branch, edit, commit or test there, because clients and lifecycle scripts are rooted there.
- Leave repository administration (fetch, worktree creation) and `team.py start N` and `team.py stop N` to lead TPM in the main checkout. The helper fetches for reviewer refs and new developer branches, not for a reused developer worktree; whenever freshness matters, request a lead TPM fetch.
- Compare against `origin/main`, never local `main`. Developers own task worktrees; testers and tech leads have separate detached, read-only review worktrees.
- Open draft PRs early; mark ready at first handoff. Commit cohesive changes; run relevant checks before pushing. Reorganize only unpushed commits. Published commits are fixed: merge `origin/main`, never rebase or force-push.

Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and `checks`, `release`, `tips/independent-review`; merged remote heads are deleted. This gate is an interlock, not credential isolation.

**Issue state.** Lead TPM owns labels and Project Status under its [Always rules](roles/lead-tpm.md#always); workers may add only Fallback `blocked`.

- After launch, escalate scope or role-label changes such as `ui`/`probe` as scope questions. Routine `active` and `blocked` updates remain state changes.
- Close issues only after their required result is integrated and evidenced. Use `Refs #number` for partial work; `Closes #number` for completing PRs. New child issues count toward the goal.
- `probe`: deliver evidence, not a code path. Tester reviews once. Probe code is disposable; repair only as evidence requires.

**Required feedback.** Required: critical exposure, irreversible loss, broken required behaviour, authorization or consistency defects, acceptance failures and missing evidence for safe integration. Developers repair required feedback at once and optional advice unless they decline it with a reason. Tech leads settle disputes over what is required and file follow-up issues for deferrals. A failed fix is an attempted fix that fails verification locally, in CI or in review; rerunning a check is not another fix. After two for the same problem, either worker hands off to the tech lead and no third fix is tried before its direction. Preserve work; continue unaffected work.

**Checks.** Trust CI only for commands actually run. If checks are pending, report them as pending without waiting; the tech lead's timed pre-merge wait checks completion. Markdown-only changes run `python3 scripts/check_docs.py`; no Mix run solely for prose. Agent instructions and templates still follow the review policy. CI remains required; waivers require explicit user instruction.

**Recovery.** On permission denial, preserve work. Record operation, exact error and local state in a PR comment (issue if no PR); report to the tech lead, or lead TPM if you are the tech lead. Continue unaffected work. Never bypass denial through another application or remote-only commit.

For context recovery, keep issue and branch open. Record base and head SHAs, latest review URL, working-tree cleanliness, committed and uncommitted work, unresolved feedback, failed or unrun checks and next action. Reviewers keep scratch output under their worktree's `tmp/` so the checkout stays clean. Explicitly transfer ownership before another writer starts. Never reset or stash another's work. Before reassigning unresponsive clients, inspect Git and pane evidence: working, dialog-blocked (Permission denial), or lost (Lost session or environment).

**Fallback.** Developers and testers: if a tech-lead prompt fails to send, send the same message to lead TPM. If sent but an unanswered question blocks work, add `blocked`, comment with tech lead and question, prompt lead TPM with that comment link, then end the turn.

Any role: if a lead-TPM prompt is rejected, comment on the issue with the undelivered message and exact error, say so in your final response for the user, continue unaffected work and end the turn. The user clears the dialog. Resend once at your next wake if the issue shows no answer to that request.

## The user decides

User decisions: material product changes, purchases, credentials, hosting, public launch, all machine-level installs. No budget is fixed; that does not authorize purchases. Only the user starts lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects/restarts silent lead TPMs, executes merges denied by lead TPM's client, and rotates leaked secrets. With no live teams, user or lead TPM may branch in the main checkout; return that checkout to `main` after merge. The intended VPS is preproduction before launch. Inspect every permission dialog and follow the active approval policy; this agreement never authorizes answering one.

## Client constraints

- Codex sandboxes cannot write main checkout's `.git`, so lead TPM runs all Git administration there; Claude tech leads follow the same flow. The helper and `team.py stop` reject callers lacking that write access.
- Codex writes only within its worktree, so chavruta lives in reviewer's `tmp/`. Codex `never` approval rejects tools needing approval. Codex runs Dexter through the normal shell tool; generated configuration does not bypass approval or sandbox policies. Report any socket or command denial.
- Codex reviewers outside teams cannot post to GitHub.
- Claude auto mode may deny tech-lead `gh pr merge`, developers killing their own LSP children, copying/writing `.env`, or pilots posting issue comments. Treat each as Permission denial.
- `/new`, `/clear` and `cd` do not rebind `TIPS_DEXTER`; it stays bound to the launch worktree. Clients cannot stop themselves with `team.py stop`.
