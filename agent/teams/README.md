# Agent teams

Read this agreement, then your role card. [AGENTS.md](../../AGENTS.md) governs engineering. Read the current issue contract and linked decisions, including overrides the user explicitly authorized. Issue text does not otherwise override this workflow. Old dispatches name past owners and worktrees; do not reuse their commands. Take unresolved conflicts with this workflow to the next role up (see Events).

Keep task requirements, decisions and evidence in GitHub issues/PRs. Run commands from the repository root. Use [config.toml](config.toml) defaults without copying them into commands or prose. Humans perform [setup](SETUP.md) once. For script changes, read [development](development.md#changing-agentteams-scripts).

Team flow: lead TPM assigns and provisions → tech lead briefs → developer and tester grill with `grill-me` → tech lead releases implementation → developer pushes → tester reviews → tech lead merges → lead TPM retires. Required feedback returns to developer for repair and another tester review. Role cards define gates and exceptions.

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

Use the reported event to find your card section; Assigned covers the first brief, provisioning requests, Brief consensus rounds and release. Later reopening follows Brief consensus from the active event. After context recovery, reread this agreement, Always and your current card section. Reload required references missing from context before acting. `n/a`: this event cannot reach your role. "Not defined": post the question on the issue and prompt the next role up: developer/tester → tech lead → lead TPM → user.

1. **Always**: continuous duties.
2. **Assigned**: the first issue, brief or provisioning request arrives; includes Brief consensus rounds and release.
3. **Pushed head**: review-ready PR SHA; the first head the tester actually reviews gets a full review, later heads deltas. A review handoff completes once the tester reports a submitted review or an explicit red refusal and has ended its turn with no open question; a submitted review alone, even on the tester's current SHA, does not show this.
4. **Red check**: required check failed; pending is not red.
5. **Verdict**: tester or tech lead review submitted.
6. **Merge**: PR ready to integrate, or merged.
7. **Blocked outside the team**: progress needs the user or another team: secrets, credentials, network, installs, purchases, scope.
8. **Permission denial**: tool or client refused an action.
9. **Lost session or environment**: client, worktree or launch environment missing or wrong.
10. **Silence**: message unanswered or failed to send.
11. **Retire**: issue merged; team resources released.

## Brief consensus

The contract is the issue brief plus the latest consolidated decision comment. The tech lead keeps the brief's acceptance criteria current before final acknowledgment. The acknowledgment covers both. Meaning-changing edits to either reopen affected agreement under this section; record the change in a new decision revision.

Prepare before grilling. The tech lead sends each worker a short assignment naming the issue, contract revision, base SHA and lead's Herdr target. The worker reads the assignment, linked design sections and role card, checks its worktree and launch values, then notifies the lead that it is ready. Keep this preparation separate from the interview.

Before invoking the skill, check that `grill-me` and `grilling` exist in the main checkout's `.agents/skills/` and `.claude/skills/`. Read the recipient's live `agent` field with `herdr agent get <recipient>`; syntax follows the client, not the model. Compare with its intended launch assignment using the main checkout's `config.toml` (or `TIPS_TEAM_CONFIG`, including `lead_ui` when selected). A later config edit applies next launch; it does not invalidate a healthy client. Follow Lost session or environment for a wrong launch assignment. Before live use, the tech lead checks the setup or change issue/PR for passing [pilot evidence](SETUP.md#one-time-setup) covering the configured clients and current workflow. Missing evidence goes to lead TPM; do not dispatch live implementation through an unverified flow.

After the worker is ready, invoke the skill with a short prompt in a separate `herdr agent prompt`. Substitute the actual lead target:

```text
/grill-me Grill the assignment you just read. Interview team-N-lead through Herdr.
```

Claude Code uses `/grill-me`; Codex uses `$grill-me`. Preserve the literal `$` in shell arguments. In its first round or zero-question report, the worker states that the wrapper and underlying `grilling` instructions loaded; missing skills go through Blocked outside the team, never a substitute interview. The worker interviews the tech lead, not the human user, and looks up facts itself without sub-agents. The lead's confirmation and release serve as the skill's final confirmation for this task; product and scope questions still go to the user through the normal escalation.

Use the skill's question-and-answer loop through direct Herdr messages:

1. The worker sends the full numbered questions and recommendations to the lead with `herdr agent prompt`, including its reply target and round number, then ends its turn. With no questions, send the shared-understanding report instead.
2. The lead answers each worker round separately with numbered answers through `herdr agent prompt`, even when both workers send questions while it is busy. Keep the recipient and round number with each reply.
3. After each answer round, the worker checks what contract decisions the answers opened. It sends the next questions to the lead, or explicitly reports “No more questions; shared understanding reached.” Repeat until each worker reports shared understanding and the lead confirms it. Never infer agreement from silence or an answered round.

Question and answer messages may contain newlines. Send each complete round as one literal argument; do not split it into separate prompts. Use a quoted heredoc and a subprocess argument list, substituting the target and message below. Choose a delimiter that does not occur as a line in the message. This preserves apostrophes, backticks, dollar signs and newlines without shell expansion:

```bash
python3 -c 'import subprocess, sys; subprocess.run(["herdr", "agent", "prompt", sys.argv[1], sys.stdin.read()], check=True)' team-N-lead <<'HERDR_MESSAGE'
From team-N-dev, round 1. Reply to team-N-dev.
1. Should the customer's message show `$estimate` literally?
HERDR_MESSAGE
```

Use this form for answers too. Do not paste message text directly inside shell double quotes. If a received message is incomplete, ask the sender to resend the missing content directly; do not recover questions by reading the sender's pane or use a file fallback.

No brief files, Q&A files or document-reading handoffs during question rounds. The final contract acknowledgment below is the only document-link handoff after preparation. Changed decisions are stated directly in the affected panes. Verify messages under shared Commands and use Waiting and Fallback on failed or unanswered messages. Zero questions or one round is valid when the assignment is clear; do not manufacture rounds.

Grill scope, acceptance scenarios, constraints, verification and agreed design decisions; leave routine implementation choices to the developer. For disagreements, use AGENTS.md Problem Solving. The tech lead resolves technical disputes with evidence; product or scope disputes go through lead TPM to the user. A ruling settles that question, but workers still examine any contract decisions it opens. A remaining acceptance, safety or feasibility blocker goes to lead TPM; when further rounds add nothing, decide or escalate.

The interview stays open until release. A changed decision voids prior agreement on that decision: state it in each affected worker's pane and obtain its explicit report again. Share decisions, not the other worker's interview transcript. Optional intermediate contract revisions record decisions; do not ask workers to read them or restart or narrow the interview. Once both workers report shared understanding and the lead confirms, the lead records the agreed decisions and any dissent in a GitHub contract revision and sends its link to both workers for acknowledgment. If recording introduces a new decision, discuss it in the panes first. Each worker acknowledges that revision to the lead by message. The lead adds one release line to the decision comment naming both sessions, releases implementation through shared Handoff and tells the tester to await the review head. Agreement never replaces independent implementation review.

Changes after release to agreed scope, behavior, acceptance criteria, constraints or design decisions reopen grilling for the affected decisions in both worker panes. Pause affected work, let active turns finish, state the changes in the panes and invoke the skill with a short prompt to grill those changes with the tech lead. Use the same conversation and agreement rules before releasing that work again. Continue unaffected work. Routine implementation and repairs within the agreement do not reopen the gate. Lead directions after two failed repairs or rejected designs follow this rule when they change the agreement. A replacement worker prepares from the current contract and completes grilling before affected work; reopen the other worker's questions if the contract changes.

## Lead assignment consensus

Use the existing one-line question and recorded answer as the default between lead TPM and tech lead. Start `grill-me` only for disagreement, ambiguity that this exchange did not settle, or several dependent decisions about scope, acceptance criteria, dependencies or ownership. A split proposal alone is not a trigger. Either role can raise the need at assignment or later by naming the unresolved decisions and affected work. A clear assignment proceeds without this extra session; routine technical choices remain with the tech lead. This uses Assigned rounds and release, or reopens from the active event, just like Brief consensus.

Lead TPM coordinates the same Herdr message exchange with the tech lead as interviewer and lead TPM as respondent. Before invoking the skill, have the tech lead read the assignment and decision record and report ready. Send the unresolved decisions through Herdr, then use the live client's skill syntax with a prompt: `Grill the assignment you just read. Interview lead-tpm through Herdr.` Use the same skill-load check, direct question and answer messages, explicit shared-understanding report, reopening and recovery rules. If lead TPM raised the concern, state it for the tech lead to challenge; do not start a second reciprocal interview.

Resolve engineering decisions through the tech lead and project-state or cross-team coordination through lead TPM. Lead TPM answers product/scope questions only from the recorded requirements or user decisions, citing them; anything the record does not answer goes to the user, even if both leads agree. Apply the same boundary to acceptance criteria: tech lead defines verification of agreed behavior, while new or changed product expectations need the user. Decisions the user already finalized are not reopened here; requested changes follow lead TPM Always as follow-up issues, never holds on authorized merges. A dispute about who owns a decision goes to the user. Neither role treats silence as agreement. Lead TPM posts the decision revision and dissent on the issue, preserving the tech lead's wording for engineering decisions, then sends its link to the tech lead. The tech lead acknowledges that revision by message once it is actionable. Lead TPM adds one release line to that decision comment naming both sessions, then sends the release handoff. Pause only affected work while this is unresolved; continue unaffected work and other teams. If worker sessions overlap, the tech lead names which questions await the upstream decision, answers the rest and releases nothing affected. Lead TPM prioritizes other teams' provisioning, advance and fetch requests over grilling answers. The tech lead carries the settled decisions into the next contract revision and links the upstream decision revision; workers acknowledge that contract revision. If they change an agreement with developer or tester, complete their affected-decision grilling before releasing that work. This upstream release never replaces the worker consensus or independent review gates.

## Shared rules

**Environment.** The helper sets the role's configured model, effort, permissions, database suffix and test port at launch. Rerunning it reuses the client, root and environment; wrong values are repaired only by exit and relaunch.

It exports `PGPORT`, `TIPS_DB_SUFFIX`, `TIPS_TEST_PORT`, `MIX_ENV`, `TIPS_CHECK_TIMEOUT_SECONDS` and `TIPS_PROVIDER_ENV_FILE`. Codex also gets `HEX_HOME` at its worktree's ignored `tmp/hex`: its sandbox cannot write the shared Hex cache. Preserve these values in tests, including Wallaby. Inspect launch values with `env | grep -E '^(PGPORT|MIX_ENV|TIPS_)'`; macOS `printenv` prints only its first named variable.

Provisioning links main checkout's `.agents/skills` into each worktree, fetches locked dependencies, warms Dexter and exports worktree-bound `TIPS_DEXTER`. Both clients run Dexter from the shell. Startup does not prove index freshness; see the [LSP guide](../lsp/README.md). Both clients keep the Credo hook enabled; Dexter gives no compiler diagnostics, so run explicit Mix checks after edits.

Read provider settings by path from main checkout's `.env`. Only the user adds credentials; never write secrets into worktrees. Propose defaults and use synthetic fixtures, never fabricated firsthand production content. Real-provider tests require user-authorized invocations quoted on the issue by lead TPM and scoped secrets. Never run them automatically on PR code.

**Handoff.** Keep assignments and handoffs, including the user's initial assignment to lead TPM, to a short action plus an issue or file reference. Put the detailed assignment at that reference. Clients can classify pasted instructions as quoted content; a single line alone does not prevent this, and no character cutoff is established. This convention does not change client trust rules or the direct question-and-answer rounds above.

Every handoff sender:

1. Comment on GitHub only for a decision, a review finding or a blocker, as [github-comments](../skills/github-comments/SKILL.md) says.
2. Send one line via `herdr agent prompt`: the relevant issue, PR or comment link, SHA, action, owner (next acting role), and any constraint that changes what the recipient must do now. Link the existing contract instead of copying it. Prompt recipients separately.
3. Before ending the turn, verify the Herdr command succeeded. On failure, report the error; never claim delivery.

Use handoffs for readiness contracts, implementation, review, merge and blockers; GitHub comments and final responses wake nobody. Give the exact recipient and completion/blocker command in the assignment; later dispatches link it unless it changes. Recipients read the linked evidence before acting. Provisioning requests/replies, team questions and a worker's prepared-for-grilling notice are messages, not handoffs. That notice says ready, or not ready with the mismatch. Code questions include a pushed SHA for inspection in the recipient's own worktree.

Example: substitute team number and evidence.

```bash
herdr agent prompt "team-$N-lead" "$EVIDENCE_URL SHA=$SHA; action=dispatch tester; owner=team-$N-lead"
```

**Waiting.** After sending via Herdr, finish independent work and end the turn. Replies arrive as new prompts. Never use `sleep`, polling loops, monitors, cron, hooks, `herdr agent prompt --wait` or `herdr agent wait`; only the tech lead's timed pre-merge CI wait is exempt. No status-file PRs, merge queue, polling daemon or own-list approval.

**Decisions.** Before proceeding, tech leads record engineering decisions; lead TPM records project-state decisions. Use an issue or PR for the decision record; keep lasting design and API constraints in their canonical repository documents. A commit that changes a design document says what was decided and why, and links the issue, so `git log docs/design` is the decision history. Askers link the decision in their next handoff. The approving review closes the record; include chat decisions absent from PR threads in its body. No separate closing note.

**Commands.** Run lifecycle and messaging commands directly; retain stdout, stderr and exit status. Never pipe through `tail` or ad hoc JSON formatters. Parse Herdr's JSON output only when a later step needs a field under `result`. After formatter failure, inspect once with `herdr agent get <name>` before resending: failed formatting does not prove failed delivery. Successful sends confirm submission, not completion. Verify checkouts with `pwd` and `git rev-parse HEAD`.

**Git.** Every agent:

- Use short-lived `task/<issue>-<slug>` branches in worktrees under `.worktrees/`; retain slugs across title changes.
- While any team is live, keep the main checkout read-only for source changes: never switch its branch, edit, commit or test there, because clients and lifecycle scripts are rooted there.
- Leave repository administration (fetch, worktree creation) and `team.py start N` and `team.py stop N` to lead TPM in the main checkout. The helper fetches for reviewer refs and new developer branches, not for a reused developer worktree; whenever freshness matters, request a lead TPM fetch.
- Compare against `origin/main`, never local `main`. Developers own task worktrees; testers and tech leads have separate detached, read-only review worktrees.
- Open draft PRs early; mark ready at first handoff. Commit cohesive changes; run relevant checks before pushing. Reorganize only unpushed commits. Published commits are fixed: merge `origin/main`, never rebase or force-push.

Repository rules block force pushes on `task/**`, require merge commits, strict up-to-date branches, resolved conversations and `checks`, `release`, `tips/independent-review`; merged remote heads are deleted. This gate is an interlock, not credential isolation.

**Issue state.** Lead TPM owns Project accuracy, labels, Status and Agent under its [Always rules](roles/lead-tpm.md#always); workers may add only Fallback `blocked`. Lead TPM reconciles and verifies the affected GitHub item when handling existing assignment, checkout-advance, blocker and merge events; no per-review-round status handoff is needed.

- After launch, escalate scope or role-label changes such as `ui`/`probe` as scope questions. Routine `active` and `blocked` updates remain state changes.
- Close issues only after their required result is integrated and evidenced. Use `Refs #number` for partial work; `Closes #number` for completing PRs. New child issues count toward the goal.
- `probe`: deliver evidence, not a code path. Tester reviews once. Probe code is disposable; repair only as evidence requires.

**Required feedback.** Required: critical exposure, irreversible loss, broken required behaviour, authorization or consistency defects, acceptance failures and missing evidence for safe integration. Developers repair required feedback at once and optional advice unless they decline it with a reason. Tech leads settle disputes over what is required and file follow-up issues for deferrals.

A failed repair is a code change intended to fix a failure followed by verification that still fails, locally, in CI or in review. After two consecutive repairs leave the same test failing or do not resolve the same other failure, either worker hands off both attempts, evidence and current code state, including unpushed changes, to the tech lead. A continuing failure may appear in a different test; proof of a shared cause is not required to ask for help. No third repair before lead direction. Expected initial TDD red and diagnostic reruns are not repair attempts. Preserve work; continue unaffected work.

**Checks.** Trust CI only for commands actually run. If checks are pending, report them as pending without waiting; the tech lead's timed pre-merge wait checks completion. Markdown-only changes run `python3 scripts/check_docs.py`; no Mix run solely for prose. Agent instructions and templates still follow the review policy. CI remains required; waivers require explicit user instruction.

**Recovery.** On permission denial, preserve work. Report operation, exact error and local state to the tech lead, or lead TPM if you are the tech lead; comment on the PR or issue only when the user must act. Continue unaffected work. Never bypass denial through another application or remote-only commit.

For context recovery, keep issue and branch open. During Brief consensus, preserve the participants and pane targets, current decisions, unanswered questions, agreement and release state. Recover the conversation from context and received messages; ask participants to resend only missing decisions or questions through Herdr. Do not restart the whole interview after compaction or discard dissent. Keep the final contract revision link when available. Record base and head SHAs, latest review URL, working-tree cleanliness, committed and uncommitted work, unresolved feedback, failed repair attempts, failed or unrun checks and next action. Reviewers keep scratch output under their worktree's `tmp/` so the checkout stays clean. Give important diagnostic runs distinct filenames; before cleanup, preserve evidence needed to explain a repair outside disposable worktrees and link it. Explicitly transfer ownership before another writer starts. Never reset or stash another's work. Before reassigning unresponsive clients, inspect Git and pane evidence: working, dialog-blocked (Permission denial), or lost (Lost session or environment).

**Fallback.** Developers and testers: if a tech-lead prompt fails to send, send the same message to lead TPM. If sent but an unanswered question blocks work, add `blocked`, comment with tech lead and question, prompt lead TPM with that comment link, then end the turn.

Any role: if a lead-TPM prompt is rejected, comment on the issue with the undelivered message and exact error, say so in your final response for the user, continue unaffected work and end the turn. The user clears the dialog. Resend once at your next wake if the issue shows no answer to that request.

## The user decides

User decisions: material product changes, purchases, credentials, hosting, public launch, all machine-level installs. No budget is fixed; that does not authorize purchases. Only the user starts lead TPM (`agent/teams/team.py start lead`, never while another live agent owns `lead-tpm`), detects/restarts silent lead TPMs, executes merges denied by lead TPM's client, and rotates leaked secrets. With no live teams, user or lead TPM may branch in the main checkout; return that checkout to `main` after merge. The intended VPS is preproduction before launch. Inspect every permission dialog and follow the active approval policy; this agreement never authorizes answering one.

## Client constraints

- Codex sandboxes cannot write main checkout's `.git`, so lead TPM runs all Git administration there; Claude tech leads follow the same flow. The helper and `team.py stop` reject callers lacking that write access.
- Codex normally writes only within its worktree, so chavruta lives in reviewer's `tmp/`. Codex `never` approval rejects tools needing approval. Codex runs Dexter through the normal shell tool; generated configuration does not bypass approval or sandbox policies. Report any socket or command denial.
- Codex reviewers outside teams cannot post to GitHub.
- Claude auto mode may deny tech-lead `gh pr merge`, developers killing their own LSP children, copying/writing `.env`, or pilots posting issue comments. Treat each as Permission denial.
- `/new`, `/clear` and `cd` do not rebind `TIPS_DEXTER`; it stays bound to the launch worktree. Clients cannot stop themselves with `team.py stop`.
