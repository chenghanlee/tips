# Team workflow

GitHub issues, PRs and reviews store the workflow state. Herdr messages start turns. One
dispatcher chooses work, opens features, starts pairs and launches reviewers and
architects. It has no shell or file tools: it acts only through the fixed operations of
[adapter.py](adapter.py), which call the commands below. Every launched client gets its
own [allocation](#allocations) and its own clone of the repository; no two clients share
a checkout. Follow
[AGENTS.md](../../AGENTS.md) and the skill for your task:
[design-software](../skills/design-software/SKILL.md),
[implement-software](../skills/implement-software/SKILL.md),
[review-software](../skills/review-software/SKILL.md). Your role file
lists your responsibilities: [dispatcher](roles/dispatcher.md),
[architect](roles/architect.md), [implementer](roles/implementer.md),
[tester](roles/tester.md). Read the [common rules](roles/common.md). The user completes
[setup](SETUP.md) once.

## How it runs

```
USER         set goals · answer product questions · start the dispatcher once · UX intake in the UX designer's pane and post the APPROVED line · report an agent that has stopped
DISPATCHER   record a bounded outcome, constraints, examples and roster → team.py start <brief>
DESIGN      unresolved consequential choice → team.py design <issue> <entry> → decision reaches affected work
UX TEAM      brief with UX: → team.py design <brief> <entry> for the UX designer and each graphic designer → intake with the user → images → candidate on task/<brief> → user posts APPROVED → team.py stop <brief> → team.py start <brief>
EVERY CLIENT bootstrap.py prepares its own clone before its first task
IMPLEMENTER  ask questions only when answers affect the work → code → push → PR "Closes #<brief>" → team.py turn <pr> <tester>
             (notifies every required reviewer of the head; asks the dispatcher to launch missing ones)
DISPATCHER   team.py review <pr> <entry> for each requested reviewer
REVIEWERS    bootstrap.py --commit <head> → brief, diff, tests → tmp/concerns.md → pr_review.py handoff <head> tmp/concerns.md prints the PR → review → notify tester if additional reviewer
TESTER       a review with a P0 or P1 → team.py turn <pr> <implementer>   (repeat until none)
TESTER       pr_review.py observe <pr> reports ready → gh pr merge → "done"
DISPATCHER   team.py stop <brief> → next
```

Agents are `[agents.<entry>]` entries in [config.toml](config.toml). A brief names its
agents: `Implementer: <entry>` and `Required reviews: <entry>, <entry>`, testers first;
a brief that changes what the user sees adds `UX: <entry>` and
`Graphic designers: <entry>, ...` ([UX design team](#ux-design-team)).
The first tester confirms the merge. A launched client is `team-<slot>-<entry>` in
Herdr; records use the entry name. Launches are recorded in the harness root's
`state/<slot>.json`, with each client's allocation and task-submission state.
`start`, `design`, `review`, `reset` and `stop` read this record and run one at a time
([launch recovery](SETUP.md#launch-recovery)).

The ordinary path uses one implementer and one independent tester covering correctness
and design. The implementer maintains the brief's technical detail and owns a coherent
working change, including justified bounded repairs under
[Design during delivery](../skills/implement-software/SKILL.md#design-during-delivery).
Working behavior and changeability are both delivery concerns. No compulsory refactor
or advance two-architect consensus is needed for settled work.

The reviewer can help with local source or verification questions when useful.
Consequential decisions go to a named architect, with independent challenge when the
unresolved alternative or risk warrants it. `design` joins a started brief in its
existing slot before a PR, including at full capacity; otherwise it creates or joins
a standalone design team. Use a shared spec when several briefs need one contract.
The [body ownership rules](roles/common.md#comments) separate recording a decision
from authority to make it. Only affected work waits for a missing decision.

### Allocations

The harness root is `agent_teams/<repository name>/` beside the main checkout (for this
repository, `../agent_teams/tips/`). An absolute `TIPS_TEAM_HARNESS` names
`<root>/harness` instead, and an installed harness uses the root its `install.json`
records. `team.py` creates the root on first use with `repository.json` naming
`github.repository`, and refuses a root that names another repository, including
another owner's repository with the same name. Each launch creates an allocation whose
ID (`g<generation>-<entry>`) never repeats:

| Path | Holds | Written by |
|---|---|---|
| `allocations/<id>/` | The client's working directory | The client |
| `allocations/<id>/project/` | The client's own clone; empty until `bootstrap.py` runs | The client |
| `allocations/<id>/logs/` | Full logs of `bootstrap.py`; `deps-fetched`, the digest of the `mix.lock` last fetched successfully | The client |
| `state/<id>/bootstrap.json` | The issue and entry, what to clone and check out, the Dexter binary and sources; deleted with the allocation | `team.py` |
| `state/<id>/retired.json` | What `stop` retired and what [cleanup](#cleanup) last did with its files and databases | `team.py` |
| `state/<slot>.json`, `state/.lock`, `state/generation` | Records, the store lock, the last generation | `team.py` |

`team.py` runs no Mix or Dexter command in a project. Its only Git commands there are
[cleanup](#cleanup)'s `git fetch --prune origin` and read-only checks in a stopped
allocation's clone. The client does:
`python3 <harness>/bootstrap.py [--commit <sha>]` clones into an empty project (the
implementer and the UX designer on `task/<brief>`, never at the same time because the
[UX design team](#ux-design-team) runs before the pair; others detached at the commit or
at `origin/main`), or
fetches an existing clone without resetting it. Without `--commit`, it finishes the
checkout of a clone that an interrupted run left off it, and refuses one with commits or
files not on origin. With `--commit`, it refuses a dirty clone and a commit that no
origin branch contains. Then it runs `mix deps.get --check-locked`
unless a fetch for the current `mix.lock` already succeeded, writes the git-ignored Dexter wrapper and skills link, starts Dexter
and updates its index. Running them is the proof that the client can clone, fetch and
index. A graphic designer's bootstrap stops after the wrapper and skills link: it reads
the brief and writes images, so it fetches no dependencies and starts no Dexter. The console shows at most 8 KiB;
the full log is in `logs/`. Each database name is `tips_test` or `tips_dev`, then
`db_suffix_prefix`, the slot, `g`, the generation and the entry's `db_suffix`, so no
generation reuses another's databases.

**Accepted risk.** Workers retain broad authority. Mistakes, misleading instructions or deliberate actions can modify the harness, records or other allocations, and a worker can perform an operation the dispatcher asks for outside the dispatcher's tool surface. Restricted dispatcher tools remove its direct execution authority (RP8c direct retry prevented) but do not enforce a worker or deputy boundary; the no-proxy rule stays procedural. The sibling root reduces accidental edits from ordinary checkout operations; it does not prevent absolute-path writes. Shared-state corruption can defeat recovery assumptions or lose work. Accepted for this MVP. Revisit after an unauthorized cross-allocation or control-file write, or a delegated denial bypass, in normal use. E0's failures stay recorded as facts, not as passing tests.

## Commands

Run worker commands from your own allocation. `<harness>` is the harness copy your
handoff names, not your clone's `agent/teams`, so a PR that changes the harness is run
with the installed one. The dispatcher runs `start`, `design`,
`review`, `stop` and `status` through its `start_pair`, `start_design`,
`launch_reviewer`, `retire_team` and `status` tools, from the main checkout. Only the
operator (the user) runs `reset` and `stop --abandon`.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <brief>` | Dispatcher | Read `Implementer:` and `Required reviews:`. For a brief with `UX:`, refuse unless a comment begins with `APPROVED candidate <SHA>` ([UX design team](#ux-design-team)). Label a new pair's brief ([Turns](#turns)). Create an allocation for the implementer (bootstrap branch `task/<brief>`) and the merge-confirming tester. Launch both in the team's workspace (see [Herdr layout](#herdr-layout)), write the record, and post one EVENT per launch on the brief. |
| `agent/teams/team.py design <issue> <entry>` | Dispatcher | Launch a configured architect in its own allocation. A started brief reuses its team slot; otherwise create or join a spec team. The issue names the lead, any critics and the question or design assignment; a new spec team needs a `Lead: <entry>` line naming a configured architect and labels the spec ([Turns](#turns)). For a UX or graphic entry, launch it into the brief's [UX design team](#ux-design-team) instead; refused once the brief holds a pair. Post its launch EVENT on that issue. The adapter keeps the argument name `spec` for either issue number. |
| `python3 <harness>/team.py turn <pr> <tester entry>` | Implementer | Require your own clone to be clean at the PR head and the PR to close the brief. Read the PR's live state (see `observe`); refuse unless GitHub reports the head mergeable. Label the brief ([Turns](#turns)). Notify every launched required reviewer of the head, its base and the `bootstrap.py --commit` command that moves its clone there; the PR itself waits for `pr_review.py handoff`. For each reviewer not launched, post a pending EVENT on the PR and ask the dispatcher to run its `review` command. Try every send; report each failed one. |
| `python3 <harness>/team.py turn <pr> <implementer entry>` | Tester | Read the PR's live state and label the brief ([Turns](#turns)). Notify the implementer with its merge conflict and failed required checks. Your clone's state does not block it. |
| `agent/teams/team.py review <pr> <entry>` | Dispatcher | For a reviewer in the brief other than the merge-confirming tester: create its allocation, configured for the PR head, with its own database suffix and port, and launch the reviewer in the team's workspace. |
| `agent/teams/team.py reset <issue> <entry>` | Operator | Record the operator's decision, after checking a stopped client's work on the issue and PR, that `start`, `design` or `review` may launch a replacement in the same allocation that gets the task again. Refuse a running client. |
| `agent/teams/team.py stop <issue>` | Dispatcher | See [Retirement](#retirement). |
| `agent/teams/team.py stop <issue> --abandon` | Operator | Retire a brief closed without a merged PR ([steps](#retire-a-brief-closed-without-a-merged-pr)). |
| `agent/teams/team.py cleanup <issue>` | Operator | Rerun [cleanup](#cleanup) for the issue's retired allocations: after an interrupted run, once kept work is published, or for an old generation. |
| `agent/teams/team.py status` | Dispatcher, user | Every allocation record with each client's live Herdr pane, name, kind, state and session, and whether the recorded dispatcher process runs. |
| `agent/teams/team.py retained` | Operator | List retired allocations that still have files or databases, with cleanup's last result. Deletes nothing. |
| `python3 <harness>/bootstrap.py [--commit <sha>]` | Launched client | Prepare your own clone, as [Allocations](#allocations) says. |
| `python3 <harness>/read.py launch <role>` | Launched client | Print AGENTS.md, the common rules, your role file and the workflow sections item 1 of its Read list links, in order, in one call. `read.py section <file> <heading>` prints one section by heading text or slug at any depth; an unknown heading is an error, not empty output. |
| `agent/teams/board.py post <issue> <TYPE>` | Any agent | Read the body from stdin. Add the attribution header. Print the comment URL. If an identical comment already exists, reuse it instead of posting another. A worker's BLOCKED post also sets `turn:dispatcher` and notifies the dispatcher, naming any label error; the command reports either failure, and a rerun retries both, not the post. |
| `agent/teams/board.py read <issue> [--after <comment URL>]` | Any agent | Print the issue's labels and body, then every comment; with `--after`, the labels and only the comments after that checkpoint. |
| `agent/teams/board.py usage <issue>...` | Dispatcher | Token counts by model for each client a launch EVENT names, read from its session logs. A Codex client's row sums every Codex session whose rollout started in its allocation directory, so a launch EVENT that says `unknown` still counts. |
| `python3 <harness>/pr_review.py handoff <head> <concerns file>` | Reviewer | Refuse until the file names the head. Then find the one open PR at that head, refuse none or several, and print its URL, body, recent reviews and unresolved threads. Post nothing. |
| `python3 <harness>/pr_review.py list <pr>` | Any agent | Recent reviews and every unresolved thread. Display only. |
| `python3 <harness>/pr_review.py observe <pr>` | Launched client | Read the head, base, mergeability, checks and reviews within one `timeouts.github_seconds` deadline; refuse a read during which the head or base changed. Required checks are the contexts the base branch's effective rules require; a required check that has not reported blocks, and other checks are only shown. Post nothing. Judge only the current read: a merge conflict, unknown mergeability, unavailable evidence, a required check that has not passed, a missing or non-LGTM required review and an unresolved thread each block; an earlier failure that this read no longer shows does not. Exit 0 only when the PR can merge at this head. |
| `python3 <harness>/pr_review.py resolve <thread>` | Thread opener | Resolve your own thread. |
| `herdr agent prompt team-<slot>-<entry> "<review URL>"` | Other reviewer | Tell the merge-confirming tester a review exists. |
| `herdr agent prompt dispatcher "<URL> done"` | Tester | The PR merged. |

### Herdr layout

Each team has one Herdr workspace, labelled `team-<slot>-<brief>`. It has one tab per
role: `architects`, `implementers` and `reviewers`, and `ux` for the UX designer and the
graphic designers. The merge-confirming tester and additional testers share `reviewers`. Each client is a pane in its role's tab, named
after the client; a second client of a role is split off the tab's last pane. A tab
opens with its first client. `start` and `review` reopen a closed pane in the same
workspace and tab; `stop` refuses a workspace that holds a pane the record does not
name, and otherwise closes the whole workspace.

Rerunning `start`, `design` or `review` keeps a running client and sends it nothing. It
refuses a stopped client that may have received its task, and a client whose record is
missing while an earlier allocation, workspace or Herdr client of it remains. The dispatcher
reports that refusal to the user; only the operator decides on a replay
([launch recovery](SETUP.md#launch-recovery)). `review` reads the brief's
current `Required reviews:` line. To add a reviewer, run its command. The command
rejects changes to the implementer or merge-confirming tester.

### Retirement

`team.py stop <issue>` retires a team in one call and asks no client anything. It
refuses, changing nothing, unless GitHub shows the brief closed by a PR merged into
`main` within `timeouts.shell_seconds`; a standalone design team and `--abandon` skip
that check. It refuses a pane in the workspace that the record does not name and another
client in an allocation. Then it stops the recorded clients, closes the workspace and
stops each project's Dexter daemon. It keeps the reservation while any of the team's
ports still answers. It writes each allocation's `state/<id>/retired.json`, deletes the
record and runs [cleanup](#cleanup) under the same lock. Before retiring, the dispatcher
checks that any attached architect's assignment is complete or handed off.

### Cleanup

Cleanup runs at the end of `stop` and again with `agent/teams/team.py cleanup <issue>`.
It reads the issue's `retired.json` files. `stop` wrote each one after its merge check
passed, for a standalone design team, or for `--abandon`, so cleanup asks GitHub nothing.
It keeps an allocation that a live record names and an `--abandon` retirement.

- Git: in each other allocation's clone it runs `git fetch --prune origin`, then
  `git status --porcelain`, `git rev-list HEAD --branches --not --remotes=origin` and
  `git stash list`, with hooks off. Only `origin` counts. When all four succeed and the
  last three print nothing, it deletes the whole allocation folder (`project/`, `logs/`,
  `tmp/`) and `bootstrap.json`; only `retired.json` remains. Output, a failure, a
  timeout (`timeouts.launch_seconds`) or a missing `.git` keeps the folder and prints why.
  Only HEAD, the local branches and the stash of the clone's main worktree are checked:
  work kept only in a linked worktree, a tag or the reflog is lost at cleanup. Push it
  first.
- Databases: once per generation, it drops with `team.psql`, without `FORCE`, every
  database named `tips_test` or `tips_dev`, then `<db_suffix_prefix><slot>g<generation>`
  from the saved suffix, then a non-digit, recorded or not. `_team2g9` matches
  `tips_test_team2g9_haiku_rb` but not `tips_test_team2g90_sol`. A refused drop is printed
  and recorded as `refused: <error>`; the other drops go on and the slot stays released.
- Report: it prints, and writes to each `retired.json`, what it deleted, what it kept and
  why, what it failed to delete, and orphans: `allocations/g*` folders that no record or
  `retired.json` names, and namespace databases outside every live or retired
  generation, and retirements whose suffix names no generation. Orphans are listed, never
  deleted. `team.py retained` lists what remains.

Cleanup keeps no journal and recovers nothing automatically. After an interrupted run or
a failed delete, which prints the remaining paths, the operator finishes by hand or
reruns `cleanup`. A process outside Herdr that still writes into an allocation after
`stop` can lose what it writes after the Git checks, and cleanup's Git reads the clone's
own configuration, which a worker can change. Both are part of the
[accepted risk](#allocations). PR bodies must not depend on files in an allocation:
cleanup deletes them.

#### Retire a brief closed without a merged PR

`stop` refuses a brief closed without a merged PR, so its slot stays taken until the
operator runs `agent/teams/team.py stop <issue> --abandon`. It skips the merged-PR check,
keeps the team's files and databases and records why in each `retired.json`; `retained`
lists them. The dispatcher has no tool for it.

## Turns

Every message starts a turn with the recipient's full context. Send only handoffs,
`done`, `blocked`, the dispatcher's answer to a blocker, a review URL to the
merge-confirming tester, the design notices below, and the
[UX design team](#ux-design-team)'s requests, replies and `<comment URL> approved`. Do not send
acknowledgments or progress updates. Put everything the recipient needs in the message
or the linked record. After sending, end your turn, with two exceptions: after a
`question` notice, continue unaffected work; after a `hold` that reached no tester
(no affected PR is open), continue to the decision. If a send fails, you still report
it: report `blocked` with the exact command and error. Do not deliver a denied message
another way.

Design notices are `herdr agent prompt <recipient> "<comment URL> <word>"`. Posting a
comment notifies nobody (only a BLOCKED post does), so the poster sends the notice:

| Notice | From | To | After posting |
|---|---|---|---|
| `<URL> question` | implementer or UX designer | `dispatcher` | a QUESTION; the dispatcher assigns an architect |
| `<URL> answer` | architect | the agent that posted the QUESTION | an ANSWER |
| `<URL> proposal` | lead | each critic | a PROPOSAL that needs critiques |
| `<URL> critique`, `<URL> agree` | critic | the lead | a CRITIQUE or AGREE |
| `<URL> hold` | lead | each affected implementer and merge-confirming tester | the PROPOSAL of a [changed binding decision](#changed-binding-decisions) |
| `<URL> held` | merge-confirming tester | the lead | its non-LGTM hold review |
| `<URL> decision` | lead | each affected implementer and merge-confirming tester | the adopted decision |

Two labels on the brief or spec issue record the task's state: `phase:design`,
`phase:implement` or `phase:review` is the workflow step; `turn:<entry>` or
`turn:dispatcher` is the coordinating owner, the agent whose action advances the task.
Only harness commands write them ([which](roles/dispatcher.md#labels)); never add or
remove them by hand. A label is an assignment, not evidence that a prompt arrived, a
check passed or an agent runs. Helpers act on their explicit assignment without owning
the turn: an additional reviewer notified of a head, an architect assigned a QUESTION, a
critic named in a spec.

On restart, read the brief and its labels (`board.py read <issue>` prints them). Act
when `turn:<you>` or an explicit assignment authorizes the work; otherwise end your
turn. Report `blocked`, and do not repair it yourself, for a repair handoff that names a
closed PR, a missing or duplicate `phase:` or `turn:` label, or a `turn:` owner not
assigned on the issue. The dispatcher repairs labels.

## UX design team

A brief whose story changes what the user sees names `UX: <entry>` (a `ux-designer`
entry) and `Graphic designers: <entry>, ...` (one or more `graphic-designer` entries).
The lead architect writes them as [design-software Step 5](../skills/design-software/SKILL.md#step-5-briefs)
says; the dispatcher writes them when it creates a brief. Nobody can edit an issue body
from the dispatcher's tools, so a brief that lacks them goes back to the user with the
exact lines to add. The principles behind this team are in
[docs/brainstorm/ux-agent-principles-chavruta.md](../../docs/brainstorm/ux-agent-principles-chavruta.md)
and the mechanics in
[docs/brainstorm/ux-agent-mechanics-chavruta.md](../../docs/brainstorm/ux-agent-mechanics-chavruta.md).

1. Once the brief meets the release conditions except approval, the dispatcher runs
   `team.py design <brief> <entry>` for the UX entry, then for each graphic entry, and
   sets the brief's Status to Active and its Agent to the UX entry. They
   form a standalone design team on the brief in the `ux` tab, labelled `phase:design`,
   `turn:<UX entry>`. The UX designer's clone starts on `task/<brief>`; it is the
   branch's only writer. Graphic designers generate nothing until step 3.
2. The UX designer asks the user for ideas and grills to a shared understanding in its
   pane ([ux-designer](roles/ux-designer.md)).
3. It posts that understanding as a PROPOSAL, then sends requests to the graphic
   designers with `herdr agent prompt`; each replies with the path of its images and
   prompts under its own clone ([graphic-designer](roles/graphic-designer.md)).
4. It curates, iterates with the user, then commits the candidate under
   `design/<brief>/` on `task/<brief>`, pushes, and posts a PROPOSAL with the SHA and
   the images.
5. The user posts `APPROVED candidate <full SHA> for <scope> with <exceptions or none>`
   as a plain comment; the UX designer gives the user that line with the SHA filled in.
   No agent posts it: agent comments begin with a harness header,
   and `start` accepts only a comment that begins with `APPROVED candidate` and the full
   40-character SHA.
6. The UX designer checks that the comment begins with that line and names the
   candidate's SHA, then sends `herdr agent prompt dispatcher "<comment URL> approved"`. The
   dispatcher reads the comment, checks the same and that the release conditions still
   hold, runs `team.py stop <brief>` (a standalone design team
   needs no merged PR), then `team.py start <brief>`. The implementer's clone starts
   `task/<brief>` from origin and holds the candidate; before its first edit it checks
   that the approved SHA is an ancestor of HEAD. The tester compares the built screens
   with the images at the approved SHA inside its combined review.

Approval is the user's; a contradiction found while building returns to the user by the
[blocker route](#report-and-resolve-blockers). The UX designer is not relaunched after
retirement in this version: before the pair starts, UI and UX questions go to the UX
designer; after that, to the user through the dispatcher as `blocked`. A UX discovery
that changes a technical contract is a QUESTION with a `question` notice
([Turns](#turns)). An `agy` graphic designer is ready only once a real launch,
prompt, restart and `team.py stop` have been run on this machine ([setup](SETUP.md#one-time-setup));
the launcher trusts each agy allocation root in agy's settings file before the client
starts, and `stop` removes the entry with the allocation.

## PR review record

Use `COMMENT` reviews instead of native approvals because agents share one GitHub
identity. Submit one `COMMENT` review per pass on the current PR head. Put P0 and P1
findings in inline comments and P2 findings in the body, as
[Optional P2 findings](#optional-p2-findings) says:

```sh
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

```json
{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...",
 "comments": [{"path": "...", "line": 12, "body": "..."}]}
```

Put `LGTM` alone on the first line of the body when no P0, P1 or decision hold remains
and required verification is satisfied, even if the body lists Optional P2s. Otherwise
put the review decision there. Put `<entry>, <session>` on the second line. Write your
initial concerns before the PR body or another review: `pr_review.py handoff` prints
them only once `tmp/concerns.md` names the head, and the record repeats the concerns.
Resolve a thread only if
you opened it. A new head invalidates every LGTM. Review changes since your last actual
review; a first review covers the full relevant change and affected contracts, and a
later head may use the [compact record](../skills/review-software/SKILL.md#review-record).
Earlier advice is not a review.

The default tester assesses correctness and design in one investigation and record.
An additional architect follows its design-review duties.

### Severity

| Severity | Condition |
|---|---|
| P0 | A feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. |
| P1 | An acceptance scenario fails or is unproven, a required test or check is missing or failing, the change violates a [required rule](../skills/design-software/SKILL.md#required-rules), an error on an affected path is hidden, or the change significantly harms the user's experience. |
| P2 | Any other finding. |

Implementer: fix every P0 and P1. You may address [Optional P2s](#optional-p2-findings);
no disposition is required. A deferral recorded in the brief's decisions table or in a
linked follow-up issue settles P2 findings on that point while its assumptions hold. A
reached revisit trigger or new invalidating evidence returns the decision to its owner,
who can repair, revise or renew it with a reason.
Reconsideration alone does not upgrade severity or require unrelated repair. A deferral
never settles a P0 or P1 condition.

### Optional P2 findings

PR P2 findings are optional ([#515](https://github.com/chenghanlee/tips/issues/515)).
Design critiques before implementation keep their P2 rules.

- Put every P2 in an `Optional` part of the review body, not in an inline thread, with
  its `path:line`, consequence and proposed change. This holds in reviews with P0 or P1
  findings too, so no P2 thread blocks a later `LGTM`. The review skills' P2 limit
  still applies.
- An Optional item needs no reply, issue, turn or fix. Merge follows [Merge](#merge) and
  does not wait for Optional work.
- P2 is not a way to demote a missing required check, a contract failure or a
  [required rule](../skills/design-software/SKILL.md#required-rules) violation.
- A reviewer may move its own open P2 thread into Optional and resolve the thread
  without the implementer's disposition.

### Changed binding decisions

When a binding contract changes, the lead identifies affected briefs and holds their
dependent work, with the notices in [Turns](#turns):

1. The lead posts the pending decision as a PROPOSAL, then sends `<PROPOSAL URL> hold`
   to each affected brief's implementer and, for each affected open PR, its
   merge-confirming tester. The implementer pauses dependent work.
2. That tester submits a non-LGTM review linked to the pending decision and sends
   `<review URL> held` to the lead. Establish that recorded hold before making the
   changed shared contract operative; a sent pause is not an established hold. When no
   affected PR is open, there is no hold to establish: the lead continues to step 3 in
   the same turn.
3. The lead updates the authoritative shared decision and sends `<URL> decision` to the
   same implementers and testers. Each implementer incorporates its link in the brief
   before resuming affected work. The tester reviews against the adopted decision before
   replacing its hold with LGTM, even if the code SHA is unchanged.

An unrelated push does not resolve the question. Harmless clarification and ordinary
internal placement within existing contracts need no hold. `observe` does not
interpret issue comments as merge blockers.

### Merge

During the [CI pause](../../agent/docs/checks.md#github-ci-pause), first verify the PR's
applicable local check evidence and an independent review at the current head.
`observe` reads GitHub state only; an empty required-check list is not proof that local
checks ran. Report a required-status rule that still expects a paused job to the user.

Merge-confirming tester: merge only when `observe` reports the PR ready at the head:
every reviewer in `Required reviews:` has an LGTM as its latest review of that head,
every thread is resolved, any GitHub-required checks pass and GitHub reports it
mergeable.

```sh
python3 <harness>/pr_review.py observe <pr>
gh pr merge <pr> --merge --match-head-commit <sha>
```

Return failed checks or a merge conflict to the implementer with
`python3 <harness>/team.py turn <pr> <implementer entry>`. For unavailable mergeability, run
`observe` once more after about a minute in the same turn; if still unavailable, report
`blocked` with its output. Report any other refused merge with the exact error.
Unavailable is never ready.

After the merge closes the brief and deletes the branch, notify the dispatcher with `done`.

## Report and resolve blockers

Report `blocked` if you have a product or scope question, if both sides of a finding
have evidence but still disagree, or if the same finding remains after two fixes.
Post the question and the evidence on the issue with
`agent/teams/board.py post <issue> BLOCKED`; the post sets `turn:dispatcher` and
notifies the dispatcher. End your turn. Dispatcher: set Blocked. Route
consequential technical questions through [architect assignment](roles/dispatcher.md#decisions-during-implementation).
Ask the user about product, scope or tradeoffs needing the user's judgment. Record
the answer on the issue; the implementer incorporates it before affected work resumes.
Set Active and hand the turn back with `prompt_agent` and the issue's phase when the
blocker is resolved. Do
not run or retry a denied command on another agent's behalf.

If a required check fails at the head, rerun the failed tests alone in a worktree of
fetched `origin/main`. If the same failure occurs there, it is pre-existing: link or open
the issue that names them in the PR body and continue. Otherwise the failure is the PR's
to fix, including a test that fails only in the full suite.

## Constraints

- One PR per issue. Open a new issue for work outside the scope. Keep that work out of
  the current PR.
- Each client works only in its own clone. Keep its assigned database and test port in
  every run.
- Put temporary files in your clone's `tmp/`. Never change the main checkout.
- Never rewrite published commits: merge `origin/main`, no rebase or force-push.
- Provider settings come from the main checkout's `.env` through
  `TIPS_PROVIDER_ENV_FILE`. Never copy secrets into a clone. Real-provider tests need
  the user's authorization on the issue.

## Manual browser review

Browser tests (`test/tips_web/features`) run on the implementer's Claude client; a Codex
tester inspects the recorded command, head and results instead
([#432](https://github.com/chenghanlee/tips/issues/432)). Before a required manual
browser scenario, read the [browser run procedure](SETUP.md#browser-run) and perform the
preflight it names, each command in its own tool call. On failure, follow its recovery
procedure; an unresolved failure is `blocked`.

## PR body

The PR body is the implementer's handoff to every reviewer. Only the implementer edits
it. Sections, in this order:

```markdown
Closes #<brief>

## Outcome
One paragraph: what works now.

## Scenarios
| Scenario | Test | Run |
|---|---|---|
| 1 <title> | test/path_test.exs:"name" | CI run URL or local command |

A `Masking risk:` row also gives its control as an exact edit (`path:line` and the change)
and the assertion the control fails. A control the implementer found from the
implementation is recorded the same way, with the mistake it distinguishes. A test with
no scenario number gets its own row with a one-line reason.

## Affected code
Changed public functions, schemas, changesets, migrations, config, PubSub topics,
Oban workers, shared fixtures; the callers and entry points each reaches. For a
changed fact, its construct, update, read, reset, removal and late-callback paths.

## Decisions
Choices made during implementation that the brief does not record, one line each
with the reason, or "none".

## Follow-up
Issue URL for deferred work, or "none".

## Checks not run by CI
During the CI pause: the record the AGENTS.md CI pause rule requires, for all
applicable local checks. Otherwise, checks CI does not cover, or "none".
```

Reviewers: verify the body's claims rather than repeating the work it records.
