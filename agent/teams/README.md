# Agent teams

Operating agreement for the agents that build Tips. Read Events, Shared rules, The user decides, Client constraints, then your role card under `roles/`. [AGENTS.md](../../AGENTS.md) governs engineering. GitHub issues and PRs hold requirements, decisions, review history and evidence. [config.toml](config.toml) defines agent settings; never repeat its defaults in commands or prose. Humans set the machine up once with [SETUP.md](SETUP.md). Run commands from the repository root.

Role names and flags:

| Role card | Agent name | Helper flag |
|---|---|---|
| [Lead TPM](roles/lead-tpm.md) | `lead-tpm` | n/a |
| [Team TPM](roles/team-tpm.md) | `team-N-tpm` | n/a |
| [Tech lead](roles/tech-lead.md) | `team-N-lead` | `--role lead`, plus `--ui` for the `ui` lead |
| [Developer](roles/developer.md) | `team-N-dev` | `--role dev` |
| [Tester](roles/tester.md) | `team-N-test` | `--role test` |

## Events
Each role card lists these events in order. A message belongs to the event it reports; Assigned covers only the first brief and provisioning requests. `n/a`: the event cannot reach this role. "Not defined": no rule exists; post the question on the issue, then prompt the tech lead (a tech lead prompts its team TPM, a team TPM prompts `lead-tpm`, the lead TPM asks the user).

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives.
3. **Pushed head**: a review-ready SHA exists on the PR branch; a reviewer reads the first head in full and later heads as a delta.
4. **Red check**: a required check failed on a head. Pending is not red.
5. **Verdict**: a tester or tech lead round is complete.
6. **Merge**: the PR is ready to integrate, or has merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: a tool or client refused an action.
9. **Lost session or environment**: a client, worktree or launch environment is missing or wrong.
10. **Silence**: a message got no reply, or failed to send.
11. **Retire**: the issue merged and the team's resources are released.

## Shared rules
**Handoff.** For each handoff, record evidence on GitHub, then deliver its link with `herdr agent prompt`. A GitHub comment or a final chat response wakes nobody. Before ending the turn, verify the Herdr command succeeded; if it failed, report the error and do not claim delivery. A handoff is one line: evidence link, SHA, action and owner (the role that acts next); link the existing contract instead of copying it. Every dispatch names the exact recipient and the exact command to run on completion or a blocker; "reply to the lead" alone is insufficient. The same handoff serves readiness, implementation, review, merge and blockers. Provisioning requests and replies, and freeform questions between developer, tester, tech lead and team TPM, are messages, not handoffs; a code question carries a pushed SHA so the reader inspects that revision in its own worktree. Prompt each recipient separately. Example; substitute the team number and evidence:

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** Send via Herdr, finish independent work, then end the turn; the reply arrives as a new prompt. No `sleep`, polling loop, monitor, cron, hook or `--wait`. The one exception is the tech lead's timed CI wait before merge. No status-file PRs, merge queue, polling daemon or own-list approval exists.

**Decisions.** Decision-makers post on the issue or PR before proceeding: tech leads for engineering, team TPMs for project state. Only GitHub records are durable. The asker links that post in its next handoff. The approving review round is the closing record; decisions made in chat that are not already in PR threads go in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly and keep their stdout, stderr and exit status; do not pipe them through `tail` or ad hoc JSON formatters. Parse Herdr JSON only when a later step needs a returned field, under `result`. A formatter failure does not prove failed delivery; inspect once with `herdr agent get <name>` before resending. A successful send confirms submission, not completion. Confirm a checkout with `pwd` and `git rev-parse HEAD`.

**Git.** `main` is protected. Work on short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; keep the slug across title changes. While any team is live the main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there, because running clients and the lifecycle scripts are rooted at it. Repository administration such as fetch and worktree creation runs from main, by the team TPM, or by the lead TPM for `team.py start` and `team.py stop`; the helper fetches for reviewer refs and new developer branches, not when it reuses an existing developer worktree; when freshness matters, ask the TPM for an explicit fetch. Compare against `origin/main`, never local `main`. The developer owns its task worktree; the tester and tech lead have separate detached, read-only review worktrees; no agent edits another's checkout. Open a draft PR early; mark it ready at the first handoff. Commit cohesive changes and run relevant checks before pushing. Unpushed commits may be reorganized; published commits are fixed, so bring `origin/main` in by merge, never rebase. Never force-push or push implementation to `main`. Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and the `checks`, `release` and `tips/independent-review` contexts, and delete merged remote heads. That gate is an interlock, not credential isolation. A documentation-only PR needs no local test run; the required CI still runs.

**Issue state.** Add `active` when assigned. Add `blocked` when progress needs outside action, with the prerequisite, responsible role and next action in a comment; a waiting dependency is not automatically a user blocker, and `Needs from owner:` alone does not block. The team TPM owns labels; a worker adds only the Fallback `blocked`. Remove stale labels; clear `active` and `blocked` after merge. Do not mirror a workflow state machine into Project fields or keep a separate status document; the Project's Status field tracks Backlog, Ready, Active, In review, Blocked and Done, nothing finer: the lead TPM sets Ready, the team TPM sets the rest. A label change after launch is a scope question. An issue closes only when its required result is integrated and evidenced: partial work uses `Refs #number`, a completing PR uses `Closes #number`. Child issues created during the run count toward the goal. Milestone gates require end-to-end evidence on one integrated revision; closing a package requires its mandatory children and package acceptance evidence. Issues labelled `ui` get the `roles.lead_ui` tech lead, launched with `--ui`; developer and tester settings do not change. Issues labelled `probe` deliver evidence, not a code path: the tester passes once, the tech lead's review round keeps its five headings at one line each, probe code is disposable, and repairs go no further than the evidence needs.

**One comment per role.** The developer, tester and tech lead each keep one PR comment and edit it in place, adding a `## <short SHA> <outcome>` round per reviewed head, newest last, with `###` headings inside a round. Outcomes: `pushed` (developer), `pass`, `findings` or `RED` (tester), `review` (tech lead). A round lists what changed, the checks run or read, and open items, and marks the prior round's findings fixed or open. Handoffs link that comment and name the SHA; never create per-round comments.

**Independence.** Nobody reviews or merges their own implementation. The tester may ask the developer anything, but its verdict cites code, tests and evidence, never the developer's explanation, because the common GitHub identity cannot mechanically prove reviewer independence. The tech lead decides technical disputes with evidence. Scope or product questions go tech lead, team TPM, lead TPM, user. Routine technical choices belong to the responsible role. A role receives only duties its configured launch policy can execute.

**Findings.** P0 is critical exposure, irreversible loss or inability to operate. P1 is broken required behaviour, an authorization or consistency defect, or missing evidence needed to integrate safely. P2 and P3 are lower-impact defects or improvements; the developer repairs P0 and P1 at once and P2 and P3 unless the tech lead defers them; the tech lead decides which block and files follow-up issues for deferred findings, and a `findings` round whose findings are all deferred counts as a pass. Do not downgrade findings to pass. Required acceptance failures block completion regardless of severity. After repeated failed repairs, investigate the root cause.

**Recovery.** For a permission blocker, preserve the work and report the failed operation, exact error and local state in your PR comment (the issue when no PR exists) and to the tech lead (a tech lead reports to its TPM); keep working on what the denial does not touch; do not route around the denial through another application or a remote-only commit. For context recovery, keep the issue and branch open and record base and head SHAs, your PR comment URL, working-tree cleanliness, committed and uncommitted work, unresolved findings, failed or unrun checks and the next action. Reviewers keep scratch output under their worktree's `tmp/` so the checkout stays clean. Transfer ownership explicitly before another writer starts. Never reset or stash someone else's work. Before reassigning an unresponsive client, inspect Git and pane evidence: working, blocked on a dialog (Permission denial), or lost (Lost session).

**Environment.** The helper applies the role's configured model, effort, permissions, database suffix and test port in the live target process, exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS` and `TIPS_PROVIDER_ENV_FILE`, and links the main checkout's `.agents/skills` into each worktree. Leave those computed values in place for tests, including Wallaby. Read provider settings from the main checkout's `.env` by path; never write secrets into worktrees; the user puts a new credential into that `.env`. Check with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable. Startup reports client launched, not index ready: Expert indexes in the background, and nobody adds a compile gate or a probe LSP; see the [LSP guide](../lsp/README.md). Agents propose defaults and use synthetic fixtures; they never fabricate firsthand production content. Real-provider tests run only through invocations the user authorized, quoted on the issue by the lead TPM, with scoped secrets, never automatically on PR code.

**Checks.** Trust CI only for commands it ran. For the `agent/teams` Python scripts, CI is the evidence: open the `checks` run for the exact reviewed head, confirm these four steps passed, and link the run in your round:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

Developers run them in their worktree before pushing when Ruff and Pyright are already on `PATH`; otherwise CI runs them, and nobody installs them. Those scripts use only the standard library; their tests use disposable Git repositories, a fake Herdr CLI and owned child processes, never live teams, and need permission to run `ps` and signal their own children. Two reviewed `# noqa: S603` exceptions exist, on `team.py:execute` and `StopAgentTest.client`: both accept variable argument lists but run without a shell, on a resolved executable with fixed or test-owned arguments. Suppress nothing else. The tech lead reviews trusted executable selection and argument handling whenever those calls change; passing lint cannot prove subprocess safety. Settings live in [pyproject.toml](pyproject.toml). A pending check is reported as pending, not waited for; the tech lead's timed wait before merge is the completion check. The user decides secret rotation; never rewrite history.

**Secrets.** Never put credentials in logs, issues, PRs, handoffs or chat. Ordinary PR CI needs no production secrets.

**Fallback.** Developer or tester: if your prompt to the tech lead fails to send, send the same message to the team TPM. If it sent but your work is blocked on an unanswered question, add `blocked` with a comment naming the tech lead and the question, prompt the team TPM with that comment's link, then end the turn.

## The user decides
Material product changes, purchases, credentials, hosting, public launch and every machine-level install. No budget is fixed; that does not authorize purchases. Only the user starts the lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects and restarts a silent lead TPM, runs a merge the lead TPM's own client denies, and rotates a leaked secret. With no live teams, the user or the lead TPM may branch in the main checkout; return it to `main` after merge. The intended VPS is the preproduction environment before launch. Inspect every permission dialog and follow the active approval policy; this document is never permission to answer an approval prompt.

**No machine-level installs without the user's explicit approval.** No agent installs packages, tools or software or changes machine, sandbox or client configuration: `brew`, casks, `pip` or `uv tool`, `npm -g`, system or client settings, Docker images outside the compose file. Project dependencies declared in the repository go through the PR like any other change. When a task truly needs an install, the tech lead has the TPM mark the issue `blocked` with the exact command and the team continues unaffected work; the lead TPM asks the user, quotes the answer in an issue comment, the user runs the install, and the agent proceeds only from that link.

**Owner waiver.** With no live teams, the user may waive the independent review of a change they requested in the session. Only on the user's explicit instruction, the user or the lead TPM runs `publish_review.py --pr "$PR" --sha "$SHA" --owner-waiver "<reason>"` instead of `--record`; it posts a waiver comment on the PR and publishes the status pointing at it. Agents never invoke it on their own, and it does not waive CI. For a waived change that touches code, complete the ad-hoc Codex review in the lead TPM's Merge cell first, apply the accepted fixes, post the agreed outcome on the PR, then publish the waiver on the final head; the waiver covers the lead TPM's own fixes. Documentation-only changes need no Codex review. The lead TPM then merges with the same native command as a tech lead and records the four merge items.

## Client constraints
- A Codex sandbox cannot write main's `.git`, so the team TPM runs all main-checkout Git administration; Claude tech leads follow the same flow. The helper and `team.py stop` refuse a caller that cannot write main's `.git`.
- A Codex sandbox writes only under its own worktree root, which is why the chavruta file lives under the reviewer's `tmp/`. Codex `never` approval rejects any tool that requires approval, so the generated config sets per-tool approval for the four LSP tools only and leaves the sandbox as the user configured it.
- A Codex reviewer outside a team cannot post to GitHub.
- Claude auto mode may deny a tech lead's `gh pr merge`, a developer killing its own LSP child, copying or writing `.env`, and a pilot posting issue comments. Each is a permission denial.
- `/new`, `/clear` and `cd` inside a running client do not reroot its LSP. A client cannot stop itself through `team.py stop`. `--kind` is optional and must match the role's configured kind.

