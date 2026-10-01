# Agent teams

Agents building Tips: read this agreement, then your role card. [AGENTS.md](../../AGENTS.md) governs engineering. Keep requirements, decisions, review history and evidence in GitHub issues/PRs. Never repeat [config.toml](config.toml) defaults in commands or prose. Humans perform [SETUP.md](SETUP.md) once. Run commands from the repository root.

Team flow: lead TPM assigns and provisions → tech lead briefs → developer pushes → tester reviews → tech lead merges → lead TPM retires. Blocking findings return to developer for repair and another tester verdict. Role cards define gates and exceptions.

| Role card | Agent name | Helper flag |
|---|---|---|
| [Lead TPM](roles/lead-tpm.md) | `lead-tpm` | n/a |
| [Tech lead](roles/tech-lead.md) | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| [Developer](roles/developer.md) | `team-N-dev` | `--role dev` |
| [Tester](roles/tester.md) | `team-N-test` | `--role test` |

## Events

Classify messages by the reported event; Assigned covers only the first brief and provisioning requests. Each card uses this order. `n/a` means the event cannot reach that role. "Not defined" means no rule exists: post the question on the issue, then prompt the next role up: worker (developer or tester) → tech lead → lead TPM → user.

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives.
3. **Pushed head**: review-ready PR SHA; the tester reads the first head fully, later heads as deltas.
4. **Red check**: required check failed; pending is not red.
5. **Verdict**: tester or tech lead round completed.
6. **Merge**: PR ready to integrate, or merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: tool or client refused an action.
9. **Lost session or environment**: client, worktree or launch environment missing or wrong.
10. **Silence**: message unanswered or failed to send.
11. **Retire**: issue merged; team resources released.

## Shared rules

**Handoff.** Every handoff sender:

1. Record evidence on GitHub.
2. Send one line via `herdr agent prompt`: evidence link, SHA, action, owner (next acting role). Link the existing contract instead of copying it. Prompt recipients separately.
3. Before ending the turn, verify the Herdr command succeeded. On failure, report the error; never claim delivery.

GitHub comments and final chat responses wake nobody. Use this handoff for readiness, implementation, review, merge and blockers. Every dispatch must name the exact recipient and completion/blocker command; “reply to the lead” is insufficient. Provisioning requests/replies and freeform questions among developer, tester, tech lead and lead TPM are messages, not handoffs. Code questions must include a pushed SHA for inspection in the recipient's own worktree.

Example: substitute team number and evidence.

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** After sending via Herdr, finish independent work and end the turn. Replies arrive as new prompts. Never use `sleep`, polling loops, monitors, cron, hooks or `--wait`; only the tech lead's timed pre-merge CI wait is exempt. No status-file PRs, merge queue, polling daemon or own-list approval.

**Decisions.** Before proceeding, tech leads record engineering decisions; lead TPM records project-state decisions. Use an issue or PR: only GitHub records are durable. Askers link the decision in their next handoff. The approving review round closes the record; include chat decisions absent from PR threads in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly; retain stdout, stderr and exit status. Never pipe through `tail` or ad hoc JSON formatters. Parse Herdr's JSON output only when a later step needs a field under `result`. After formatter failure, inspect once with `herdr agent get <name>` before resending: failed formatting does not prove failed delivery. Successful sends confirm submission, not completion. Verify checkouts with `pwd` and `git rev-parse HEAD`.

**Git.** Every agent:

- Use short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; retain slugs across title changes. Never push implementation to protected `main`.
- While any team is live, keep the main checkout read-only for source changes: never switch its branch, edit, commit or test there, because clients and lifecycle scripts are rooted there.
- Leave repository administration (fetch, worktree creation) and `team.py start N` and `team.py stop N` to lead TPM in the main checkout. The helper fetches for reviewer refs and new developer branches, not for a reused developer worktree; whenever freshness matters, request a lead TPM fetch.
- Compare against `origin/main`, never local `main`. Developers own task worktrees; testers and tech leads have separate detached, read-only review worktrees. Never edit another agent's checkout.
- Open draft PRs early; mark ready at first handoff. Commit cohesive changes; run relevant checks before pushing. Reorganize only unpushed commits. Published commits are fixed: merge `origin/main`, never rebase or force-push.

Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and `checks`, `release`, `tips/independent-review`; merged remote heads are deleted. This gate is an interlock, not credential isolation. Documentation-only PRs skip local tests, never required CI.

**Issue state.** Lead TPM owns labels; workers may add only Fallback `blocked`.

- Assignment: add `active`.
- Progress needs outside action: add `blocked`; comment with prerequisite, responsible role and next action. A waiting dependency is not automatically a user blocker; a `Needs from owner:` line alone does not block.
- Remove stale labels; clear `active` and `blocked` after merge.
- Track workflow only in Project Status: Backlog, Ready, Active, In review, Blocked, Done. Lead TPM sets them. Never add finer workflow states or a separate status document.
- After launch, escalate scope or role-label changes such as `ui`/`probe` as scope questions. Routine `active` and `blocked` updates remain state changes.
- Close issues only after their required result is integrated and evidenced. Use `Refs #number` for partial work; `Closes #number` for completing PRs. New child issues count toward the goal.
- Milestone gates need end-to-end evidence on one integrated revision. Package closure needs mandatory children and package acceptance evidence.
- Issues labelled `ui` get the `roles.lead_ui` tech lead, launched with `--ui`; developer and tester settings stay unchanged.
- `probe`: deliver evidence, not a code path. Tester passes once; tech lead keeps five review headings, one line each. Probe code is disposable; repair only as evidence requires.

**One comment per role.** Developer, tester and tech lead each edit one PR comment. Append `## <short SHA> <outcome>` per reviewed head, newest last, with `###` headings. Outcomes: developer `pushed`; tester `pass`, `findings`, `RED`; tech lead `review`, short until the Merge round. Each round lists changes, checks run or read and open items; mark prior findings fixed or open. Handoffs link this comment and SHA. Never create per-round comments.

**Independence.** Never review or merge your own implementation. Testers may question developers, but the verdict cites code, tests and evidence, never developer explanations, because the shared GitHub identity cannot mechanically prove independence. Tech leads settle technical disputes with evidence. Route scope/product questions through tech lead → lead TPM → user. Responsible roles decide routine technical choices. Assign only duties the role's configured launch policy can execute.

**Findings.** P0: critical exposure, irreversible loss or inability to operate. P1: broken required behaviour, authorization/consistency defects or missing evidence for safe integration. P2/P3: lower-impact defects or improvements. Developers repair P0/P1 immediately, P2/P3 unless deferred by the tech lead. Tech leads decide which findings block and file follow-up issues for deferrals. All findings deferred means the `findings` round passes; never downgrade findings to pass. Acceptance failures block regardless of severity. After repeated failed repairs, investigate the root cause.

**Recovery.** On permission denial, preserve work. Record operation, exact error and local state in your PR comment (issue if no PR); report to the tech lead, or lead TPM if you are the tech lead. Continue unaffected work. Never bypass denial through another application or remote-only commit.

For context recovery, keep issue and branch open. Record base and head SHAs, PR comment URL, working-tree cleanliness, committed and uncommitted work, unresolved findings, failed or unrun checks and next action. Reviewers keep scratch output under their worktree's `tmp/` so the checkout stays clean. Explicitly transfer ownership before another writer starts. Never reset or stash another's work. Before reassigning unresponsive clients, inspect Git and pane evidence: working, dialog-blocked (Permission denial), or lost (Lost session or environment).

**Environment.** When it launches a client, the helper applies the role’s configured model, effort, permissions, database suffix and test port. A running client keeps that environment and root: rerunning the helper reuses the session and changes neither, so a wrong environment is repaired only by exit and relaunch. The helper exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS`, `TIPS_PROVIDER_ENV_FILE`, and links main checkout's `.agents/skills` into each worktree. Preserve these values in tests, including Wallaby.

Read provider settings by path from main checkout's `.env`; only the user adds new credentials there. Never write secrets into worktrees. Inspect launch values with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable. Provisioning warms up Dexter and exports `TIPS_DEXTER`, bound to the assigned worktree; Claude also loads the generated Dexter plugin for its native LSP tool. Startup is not proof of index freshness. See the [LSP guide](../lsp/README.md). Agents propose defaults and use synthetic fixtures; never fabricate firsthand production content. Real-provider tests require user-authorized invocations quoted on the issue by lead TPM, with scoped secrets; never run automatically on PR code.

**Code navigation.** Before changing a function's name, arity or return shape,
inspect its callers with Dexter references and list them in the PR comment.
Use definition on unfamiliar call sites and hover for unfamiliar types or specs.
Follow [AGENTS.md](../../AGENTS.md) and the [operations table](../lsp/README.md#operations).
Dexter does not provide compiler diagnostics; run explicit Mix checks after edits.

**Checks.** Trust CI only for commands actually run. For `agent/teams` Python changes, CI is the evidence: open the exact-head `checks` run, verify these four steps passed and link the run in your round.

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Developers run these before pushing, in their worktree, if Ruff and Pyright are already on `PATH`; otherwise use CI. Agents never install them. Scripts use only standard-library dependencies. Tests use disposable Git repositories, fake Herdr and owned child processes, never live teams. Tests need permission to run `ps` and signal their own children.

Provisioning and client-stop changes also require the real-daemon tests (`-k real_daemons`) with `TIPS_TEST_REAL_DEXTER` and `DEXTER_ELIXIR_LIB_ROOT` set (see the [LSP guide](../lsp/README.md)); CI runs them in the `dexter` job against the freshly built binary. Changes to Codex launch arguments or generated Codex configuration also require the installed-Codex tests with `TIPS_TEST_REAL_CODEX=1`. CI has no Codex client: record the local result in your round.

The reviewed `# noqa: S603` boundaries are `team.py:execute` and `StopAgentTest.client`: variable argument lists, no shell, resolved executable, fixed or test-owned arguments. These are per-call exceptions, not a disabled security rule. Suppress nothing else. When these calls change, tech leads review trusted executable selection and arguments; passing lint cannot prove subprocess safety. Settings: [pyproject.toml](pyproject.toml). If checks are pending, report them as pending without waiting; the tech lead's timed pre-merge wait checks completion. Users decide secret rotation; never rewrite history.

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets.

**Fallback.** Developers and testers: if a tech-lead prompt fails to send, send the same message to lead TPM. If sent but an unanswered question blocks work, add `blocked`, comment with tech lead and question, prompt lead TPM with that comment link, then end the turn.

## The user decides

User decisions: material product changes, purchases, credentials, hosting, public launch, all machine-level installs. No budget is fixed; that does not authorize purchases. Only the user starts lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects/restarts silent lead TPMs, executes merges denied by lead TPM's client, and rotates leaked secrets. With no live teams, user or lead TPM may branch in the main checkout; return that checkout to `main` after merge. The intended VPS is preproduction before launch. Inspect every permission dialog and follow the active approval policy; this agreement never authorizes answering one.

**Installs.** Agents never install packages, tools or software or change machine, sandbox or client configuration: `brew`, casks, `pip`, `uv tool`, `npm -g`, system or client settings, Docker images outside compose. Only the user installs, after explicit approval. Repository-declared dependencies go through PRs. For a necessary install:

1. Tech lead asks lead TPM to add `blocked` with the exact command; team continues unaffected work.
2. Lead TPM asks user and quotes the answer on the issue.
3. User runs the install; agent proceeds only from the quoted-answer link.

**Owner waiver.** With no live teams, users may waive independent review of changes they requested in the session. Only on explicit user instruction, user or lead TPM runs `publish_review.py --pr "$PR" --sha "$SHA" --owner-waiver "<reason>"` instead of `--record`. The command posts a waiver comment and status linking it. Agents never invoke waivers independently; CI remains required.

For code changes, first complete the [lead TPM's ad-hoc Codex review](roles/lead-tpm.md#merge), apply accepted fixes and post the agreed outcome on the PR. Then publish the waiver on the final head, including lead TPM's fixes. Documentation-only changes need no Codex review. Lead TPM uses the tech lead's native merge command and records the [four merge items](roles/lead-tpm.md#merge).

## Client constraints

- Codex sandboxes cannot write main checkout's `.git`, so lead TPM runs all Git administration there; Claude tech leads follow the same flow. The helper and `team.py stop` reject callers lacking that write access.
- Codex writes only within its worktree, so chavruta lives in reviewer's `tmp/`. Codex `never` approval rejects tools needing approval. Codex runs Dexter through the normal shell tool; generated configuration does not bypass approval or sandbox policies. Report any socket or command denial.
- Codex reviewers outside teams cannot post to GitHub.
- Claude auto mode may deny tech-lead `gh pr merge`, developers killing their own LSP children, copying/writing `.env`, or pilots posting issue comments. Treat each as Permission denial.
- `/new`, `/clear` and `cd` cannot reroot a running client's LSP. Clients cannot stop themselves with `team.py stop`.
