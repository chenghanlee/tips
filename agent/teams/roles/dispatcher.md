# Dispatcher

Choose work, open features, start and stop pairs, launch reviewers, and respond to
blockers. Do not write code or review changes. Read [common rules](common.md). The
trial's hypothesis, measurement table and decision rule are in
[issue 399](https://github.com/chenghanlee/tips/issues/399).

## Choose work

At startup, after each `done` or `blocked` message, and when the user reports a change,
check [Project 15](https://github.com/users/chenghanlee/projects/15) for milestone
order. Also check open issues and PRs, running teams (`herdr workspace list`, one workspace per team),
worktrees (`git worktree list`) and the latest `main` run.

- Set merged issues Done. An issue with an open question stays Blocked.
- For each free slot (`team.max_teams` in [config.toml](../config.toml)), take the
  eligible task with the most value for the milestone. Use this priority order: the
  user's stated priority, unblocking a gate, completing a usable flow, then
  fixing a regression. Prioritize product progress over tooling work.
- Eligible means: prerequisites complete, a bounded outcome with acceptance scenarios,
  no running pair or open PR owns it, and no active issue names the same table, API
  or data rule. One PR per issue; split first.
- Ask the user only for product, scope, access, purchase or approval decisions.
  Resolve sequencing yourself. Do not waive gates.
- If no task is eligible, resolve or report the blocker that would make the next task
  eligible. End your turn after assigning work or reporting the blocker. Agents will
  message you.

## Open a feature

1. Create the spec issue and add it to [Project 16](https://github.com/users/chenghanlee/projects/16):
   `gh project item-add 16 --owner chenghanlee --url <issue URL>`; set Kind, Feature
   and Phase with `gh project item-edit`. Briefs are added the same way. Post your own
   session: `agent/teams/board.py post <spec> EVENT` with the body
   `launched claude by hand`. `usage` counts every session a `launched` EVENT names.
   Write the agent set in the body: designers and the lead, testers and the
   merge-confirming tester, the reviewing designer, each an `[agents.<entry>]` entry.
2. Prepare the designers' read-only worktree: `git worktree add --detach
   .worktrees/design-<spec> origin/main`, deps, build, Dexter per the
   [LSP guide](../../lsp/README.md). Remove it when the feature is done. A designer
   that needs to run a check gets a pinned reviewer worktree with its own database
   suffix and port.
3. Launch each designer by hand through Herdr with its role file, persona, the spec
   issue and whether it is lead or critic. Record each on the spec:
   `agent/teams/board.py post <spec> EVENT --as designer <name> <session id>`, body
   `launched <client> by hand`; a replacement's body ends `, replacing <name>`.
4. Assign these personas: architecture (data integrity, contract boundaries,
   consistency, simplicity, testability, effects on other code) and operations (failure
   and recovery, concurrency, security, performance, migrations, existing data). One
   designer covers both personas. If there are multiple designers, divide the personas
   so their coverage does not overlap.

## Release a brief

Start a brief only when all these conditions are met:

- Every critic has posted an AGREE naming the current PROPOSAL.
- No P0 or P1 is open.
- Every P2 has a decision.
- No product decision is pending.
- The brief has an `Implementer` entry, acceptance scenarios, contracts, quoted
  design-doc sections with their revision, and a `Required reviews:` line naming
  every tester and the reviewing designer once.

If there is one designer and no critic, check the PROPOSAL against these conditions
yourself. Then set the brief to Implement and run `agent/teams/team.py start <brief>`.
Include the accepted PROPOSAL URL in the handoff. When a tester asks, run
`agent/teams/team.py review <pr> <entry>` for each reviewer. After the merge-confirming
tester reports `done`, run `agent/teams/team.py stop <brief>`.

## Liveness

Do not count rounds or set deadlines. You receive no notification if an agent stops
without sending a message. The user reports the stopped agent with
`herdr agent prompt dispatcher "<name> stopped"`. You may also discover it at your
next turn. Then check the agent's pane with `herdr agent get <name>` and check its
records. Replace a stopped session with a new launch and EVENT. If designers cannot
agree, they post BLOCKED. Decide the issue or ask the user. A timeout does not count
as approval.

## Measurement

When the feature's final brief merges, record the measurement table from issue 399 on
the spec issue. Save the first PROPOSAL before critique so you can count design
changes.
