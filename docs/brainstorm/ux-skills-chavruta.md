# UX and UI skills in the agent team workflow: adversarial chavruta (Fable x Codex), 2026-10-21

Shared record. Each side appends under its own heading. Do not edit the other side's text.
Read-only: no file edits outside this record, no GitHub posts, no team.py, bootstrap, herdr or mix runs.
Plain English. Short lines. The user has ADHD. No praise, no filler, no restating.

Metric to maximize: (overall UX and UI design quality) / ((time + tokens spent by the UI agents) + (complexity of the agent team workflow)). Every rule, file, role step, hook, command or check counts as complexity. Greenfield MVP. Simplest well-engineered solution. Reuse standards and tools over inventing.

## Context (read first)

- Repo rules: AGENTS.md (Skills section), agent/skills/design-software/SKILL.md, agent/skills/implement-software/SKILL.md, agent/skills/review-software-design/SKILL.md, agent/teams/roles/{designer,implementer,tester}.md, agent/teams/README.md. Pairs: one implementer, one tester. A designer joins only for a consequential question or a design story.
- Product plan (PR #524, branch task/523, worktree .worktrees/task-523): plain HTML, CSS, JS on Phoenix controllers and HEEx. Basecoat components, Vega style. Story 1 = a form with title and body and a tip page. The real look comes in a later design story. PRD at PRODUCT.md. Design facts in docs/design.
- Three tools, all user-installed into the Git-ignored skill dirs (.claude/skills, .agents/skills), like the Elixir skills:
  1. Vercel web-design-guidelines: one 30-line skill. At use, fetches a rules file from Vercel and reviews given files for web interface guideline compliance, output as file:line findings. Already vendored in PR #524 at agent/skills/web-design-guidelines.
  2. Impeccable (pbakaus/impeccable, Apache-2.0): one skill `/impeccable <command>`, 24 commands. Relevant: `init` (writes PRODUCT.md once), `shape` (plan UX and UI before code; starts with a discovery interview), `audit` (a11y, performance, responsive checks), `critique` (UX design review), `polish`, `harden` (error handling, edge cases), `document` (writes DESIGN.md from code), `live` (browser iteration). Also installs edit hooks and a CLI with 61 deterministic detector rules.
  3. Intent (ghaida/intent, CC0): 18 skills, 6 agent personas, for the "why": `/intent:strategize`, `/intent:investigate`, `/intent:journey`, `/intent:organize`, `/intent:wireframe`, `/intent:articulate` (UX copy, error messages), `/intent:evaluate` (heuristic review), `/intent:fortify` (edge cases, 9 states per screen), `/intent:include` (accessibility), `/intent:specify` (engineering specs), and more. Install `npx skills add ghaida/intent --all`.

Overlaps: Impeccable `critique` vs Intent `evaluate` (both UX review). Impeccable `audit` vs Intent `include` vs Vercel guidelines (all accessibility and quality checks). Impeccable `harden` vs Intent `fortify` (edge cases). Intent `articulate` vs our GOV.UK error-text decision. Intent `specify` vs our brief format in design-software.

## Round 1: Fable

### Design tree

1. Where the usage rules live (root).
2. Which commands are mandatory per role, which are optional.
3. How overlaps are resolved.
4. What artifacts the commands produce and where they land.
5. How the result is verified without a second full review.

### Candidates for 1

A. One tracked reference skill `agent/skills/ux-design/SKILL.md` with a table: when, role, command, output location. The three workflow skills link to it at the step where it applies. AGENTS.md keeps one sentence pointing at it. SETUP.md gets the install lines. Role files unchanged.
B. Inline the commands in the three workflow skills (design-software, implement-software, review-software-design) at the matching steps. No new file. AGENTS.md keeps one sentence.
C. Nothing beyond AGENTS.md: one sentence naming the three tools and leaving command choice to the agent. Zero workflow change.

### My choice: A, with a small mandatory set

Why not C: an agent that must choose among 42 commands and three overlapping tools will pick differently each time, and reviews will not be comparable. Why not B: the same table would be split across three files and drift; and the overlap rules need one home.

Proposed mandatory set (everything else optional, named in the reference skill as "use when"):

| When | Role | Command | Lands in |
|---|---|---|---|
| Any story that adds or changes a page, before the PR | implementer | `/impeccable audit` on the changed pages; fix findings | the page |
| Any story with user-facing copy | implementer | `/intent:articulate` for the copy; our GOV.UK error text wins | the page; content.md if a rule changes |
| Review of any story that adds or changes a page | tester | `/impeccable critique` on the pages; `web-design-guidelines` on the templates | review findings, P0 to P2 by our severity table |
| Design story only (the look, a flow, a new area) | designer lead | `/intent:journey` then `/impeccable shape`; `/impeccable document` to write DESIGN.md | the brief; DESIGN.md at root |
| One-time, user | user | `/impeccable init` | PRODUCT.md |

Overlap rules: one tool per job. Review = Impeccable `critique` plus Vercel guidelines. Accessibility = Impeccable `audit` (it is deterministic and cheap). Edge cases = our implement-software failure sections already; Intent `fortify` only in a design story. Intent `evaluate`, `include`, `harden`, `polish` not mandatory.

Verification: the implementer records the `audit` run and its remaining findings in the PR body "Checks not run by CI". The tester reruns `critique` and the guidelines on the head; that is its design review input, not an extra pass.

### Questions for Codex (answer each; refute with path:line or a tool fact)

Q1. Is a fourth tracked skill file cheaper than inlining, given the three workflow skills already have the steps? Argue B or C against A.
Q2. Intent costs 18 skills of context and interview-style prompts (`shape` and `strategize` ask questions and stop). In a pair with no human in the loop, who answers? Should Intent be limited to design stories with the user present, and dropped from pair stories entirely?
Q3. Is `/impeccable audit` plus the Vercel guidelines double work? Pick one for the implementer and one for the tester, or show they catch different things.
Q4. `/impeccable critique` in the tester's review: how is its output mapped to our P0 to P2 severities without a new rule? Propose the smallest mapping or argue the tester should treat it as advice only.
Q5. Impeccable's edit hooks run on every file edit in the main checkout. Pairs run in clones without the hooks. Is that asymmetry a problem or fine?
Q6. DESIGN.md and PRODUCT.md at root, written by a tool: do they violate "one owner per fact" against docs/design? Propose the rule.
Q7. What is the cheapest way to tell if this adds quality: name one observable per story.
Q8. Anything I missed that moves the metric by more than any of the above.

Close with your own ranking of A, B, C by the metric and the user decisions you would ask for.

## Round 1: Codex

Product question: which tool use improves the shipped interface enough to pay for it?
Disproof signal: more review work without fewer observed usability failures.

Choose B with fewer commands. Reject the proposed mandatory set.
Its cost is much larger than the routing table suggests.

### Evidence boundary

Read the named workflow skills, roles, workflow, AGENTS.md and design index.
Read PRODUCT.md and all four design files in `.worktrees/task-523`.
The main checkout is `80c74f6467d93ddc27f8143dab143445ded27701`.
Task-523 is `dc59a638ac5484593caf5608ab50b477a2cf8541`.
Below, `plan/` means `.worktrees/task-523/`, not merged requirements.

None of the three named tool directories exists under this checkout's `.agents/skills`.
Read upstream READMEs and relevant command docs instead.
Also read the vendored guideline skill in task-523.
These are documented capabilities, not locally verified tool runs.
Upstream revisions inspected:

- Impeccable: `dad8dbb3aac21ad1fa236c110315ef4abece23e8`.
- Intent: `3fc38dff381ce0e4dec8f52c97c3e37abd95e10e`.
- Vercel rules: `434b7f91364665f2f733b310ec54809bf8f37937`.

### Q1. A fourth skill is not yet cheaper

Your drift argument assumes B repeats the same table three times.
It need not. Put each instruction at its one point of use:

- Design: choose a tool only for the unresolved UX question.
- Implementation: use settled components and copy; inspect the affected result.
- Review: apply guidelines inside the existing review, using existing severity rules.

Cross-reference shared rules instead of copying them.
`agent/skills/design-software/SKILL.md:93` already says to reference shared decisions.
`agent/skills/review-software-design/SKILL.md:13` already requires one investigation.
`agent/skills/implement-software/SKILL.md:277` already owns the finish step.
No new role, report or command catalog is needed.

A adds another lookup plus links from three skills and AGENTS.md.
That may pay later if several roles need substantial shared policy.
It does not pay merely because three products have overlapping command names.

C is a reasonable trial baseline, not automatically chaotic.
Acceptance scenarios and severity make reviews comparable.
Identical command names do not make probabilistic reviews comparable.
The existing tester already covers correctness and design:
`agent/teams/README.md:43`.

### Q2. Remove mandatory Intent from ordinary pairs

Eighteen installed skills does not establish eighteen full prompts per task.
The [Intent README](https://github.com/ghaida/intent/blob/3fc38dff381ce0e4dec8f52c97c3e37abd95e10e/README.md)
lists separate skills and describes the six-persona setup for its plugin.
It gives no measured token cost for our pair workflow.
Do not confuse package size, discovery overhead and loaded instructions.

Still, mandatory `articulate` for every label has no demonstrated benefit here.
`plan/docs/design/content.md:24` already owns the error wording.
Use that wording directly. A new button label does not need a voice framework.
Use Intent selectively when copy or a flow has an actual unresolved problem.
Do not ban it from pairs merely because it can also run interviews.

`shape` belongs to Impeccable, not Intent.
Its [command docs](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/shape.md)
require confirmation and stop; without a human or structured answer mechanism,
they return assumptions and stop.
An agent cannot turn those assumptions into user approval.

The brief and PRODUCT.md answer settled questions.
The user answers missing product choices through the existing dispatcher route:
`agent/teams/README.md:397`.
Do the interactive design work before launching dependent implementation.
Even a design story should not automatically run both `journey` and `shape`.
`shape` already covers audience, outcome, states, interaction and layout.

### Q3. Audit is not the deterministic command

The [audit instructions](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/audit.md)
ask an agent to assess five dimensions, score them and write a report.
They include a detector run, but the whole command is not deterministic.
They explicitly leave fixes to later work.
Thus the proposed output location, "the page", omits the audit report and repair pass.

Audit and [Vercel's rules](https://github.com/vercel-labs/web-interface-guidelines/blob/434b7f91364665f2f733b310ec54809bf8f37937/command.md)
overlap on labels, focus, semantics, motion, images and overflow.
Audit additionally scores theming and implementation integrity.
Vercel includes navigation state and form behavior.
Different coverage exists; it does not justify both full passes on every page.

If choosing one tool for each role, trial this:

- Implementer: Impeccable `detect` on the rendered affected page.
- Tester: Vercel guidelines on the affected templates, styles and scripts,
  alongside the existing browser scenario.

The [Impeccable CLI docs](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/README.md#cli)
distinguish exit 0, findings at exit 2, and scan failure at exit 1.
A clean scan does not prove accessibility or visual quality.
Do not introduce this as a required check before testing it on our HEEx output.
For now, make the detector optional and keep the existing verification obligations.

The tester verifies concrete problems independently, not the implementer's score.
No full rerun of audit, critique and guidelines is needed to achieve that.
`agent/teams/README.md:319` already says to verify claims without repeating the work.

### Q4. Reclassify consequences; do not translate labels

Treat tool output as candidate findings.
Validate each one, then apply `agent/teams/README.md:325` directly:

- Feature cannot complete, unauthorized action, or stored data loss: P0.
- Failed acceptance, missing required evidence, hidden error,
  required-rule violation, or significant UX harm: P1.
- Everything else: P2, optional in a PR.

No second severity table.
A tool's P3 becomes an optional P2 only if worth reporting.
A tool's P1 does not establish our P1 without the underlying consequence.
Respect the combined limit of three P2s:
`agent/skills/review-software-design/SKILL.md:18`.
"Fix findings" must not quietly turn all aesthetic advice into release gates.

More seriously, mandatory `critique` is not merely another review lens.
Its [current instructions](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/critique.md)
require two isolated assessments when sub-agents are available,
detector/browser evidence, a persisted snapshot, and closing user questions.
They contain a Codex permission gate and require questions at three priority issues.
This adds agent work and interaction to the two-person pair.
It conflicts with the claim that the tool is just input to one existing pass.
Keep the full command optional for a deliberate design review with the user.

### Q5. Hook asymmetry is acceptable only for optional assistance

The premise is too broad: the hooks do not scan every file edit.
The [hook docs](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/hooks.md)
list supported UI extensions and split immediate checks from a deeper stop pass.
HEEx and `.ex` are absent from the default extension list.
Server templates need explicit extension configuration.
Rendered-page scanning avoids treating an unscanned template as clean.

`agent/teams/bootstrap.py:250` links `.agents/skills` into clones.
It does not provision the provider hook manifests there.
Skill availability and hook activation are separate facts.
I did not inspect private client settings, so local activation remains unverified.

Do not add clone hooks merely for symmetry.
Optional editor help can differ while acceptance and verification stay the same.
If a detector later becomes mandatory, run it explicitly on the reviewable head.
That makes evidence independent of which edits happened to trigger a hook.
Machine/client installation stays the user's action under `AGENTS.md:15`.

### Q6. File names are not the ownership problem

PRODUCT.md already owns purpose, audience and principles:
`plan/PRODUCT.md:66` and `plan/docs/design/README.md:5`.
Technical facts remain in docs/design.
Do not require `init` just to recreate existing product context.
Task-523 currently proposes that setup run at `plan/agent/teams/SETUP.md:36`;
I would remove the unconditional requirement.

DESIGN.md can own an approved visual system without duplicating technical contracts.
But no approved system needs documenting before the later design story:
`plan/docs/design/decisions.md:11`.
Do not make the designer extract a final system before its implementation exists.

Proposed rule: each adopted fact has one authoritative home;
other files link to it. Generated observations cannot silently change authority.
Keep error copy in content.md, product intent in PRODUCT.md,
and implementation tokens in their chosen source.
Add DESIGN.md only when it serves an actual consumer and its scope is agreed.

The [document command](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/document.md)
does more than write prose: it defines normative token frontmatter,
asks for qualitative input, and normally writes a design.json sidecar.
Adopting it means deciding token authority and artifact ownership too.
The required code rule at `agent/skills/design-software/SKILL.md:108`
is not automatic grounds to call any repeated documentation a P1.
The practical problem is contradictory instructions and upkeep.

### Q7. Observe unassisted completion at the existing demo

One observable per story: does the user complete its primary task
without an agent explaining the interface? Record yes/no and the failure point.

For story 1: submit a tip, recover from an invalid field,
and recognize the saved result without coaching.
This uses the already planned demo at `plan/PRODUCT.md:54`.
Record it in the existing story decision, not a new scorecard.

It is a cheap usability signal, not proof of overall design quality
or of a tool's causal effect. Different stories are not controlled comparisons.
If the tool trial reports a benefit, name the concrete issue it caught and fixed.
Use existing session usage and review turns to assess cost;
`agent/teams/README.md:118` already describes token reporting.
Do not optimize for finding counts or the tool's own health score.

### Q8. The larger costs are execution policy and missing visual evidence

First, the full tool workflow is much bigger than its command name.
Two critique agents and forced interviews outweigh one extra Markdown file.
Settle mandatory behavior before debating where its table lives.

Second, generic tool advice can undo a deliberate product choice.
Basecoat and Vega are already selected at `plan/docs/design/decisions.md:21`.
Do not replace them to satisfy a generic taste warning.
Review what users can see and do within the chosen system.
Deferred polish does not excuse unreadable text or unusable controls.

Third, our failure rules mostly cover software behavior.
They do not establish that error text is visible, focus reaches it,
or a long title remains readable on a narrow screen.
Compare `agent/skills/implement-software/SKILL.md:140`
with `plan/docs/design/content.md:36`.
The cheapest missing evidence is inspection of the actual affected states.
Use the planned scenario screenshots and manual browser check,
already named at `plan/docs/design/decisions.md:25`.
A screenshot supports layout judgment; keyboard behavior still needs interaction.

Fourth, a vendored launcher does not freeze its fetched rules.
`plan/agent/skills/web-design-guidelines/SKILL.md:16` fetches the latest rules.
Record the rules revision in the existing review evidence when used.
Do not let a remote update silently expand the brief or its required checks.

Finally, the proposed artifact list is incomplete.
Upstream [installation documentation](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/README.md#keeping-impeccable-out-of-git)
expects some `.impeccable` files to be shared, including surface contracts
and critique reports. Task-523 says its config is ignored at
`plan/agent/teams/SETUP.md:40`.
Resolve that mismatch only if those commands are adopted.
Do not create a second spec and review archive by accident.

### Ranking and user decisions

1. B, with the reduced set above. Put narrow guidance at existing steps.
   One applicable guideline review; optional detector; interactive tools by need.
2. C. Cheapest baseline while learning whether the tools improve real stories.
   Weaker routing, but existing scope, severity and review rules still apply.
3. A. Most upkeep before any demonstrated reuse benefit.
   Revisit only when repeated shared policy makes B harder to maintain.

This ranks expected value, not measured results.
With the same large mandatory set, neither A nor B fixes its dominant cost.

Decisions I would ask the user for:

- Trial the reduced B approach for the first form and later design story,
  then retain only tool use that caught a concrete problem worth its cost?
- Keep full `shape`, `critique` and `document` workflows for sessions
  where the user deliberately wants their interviews and artifacts?
- When the visual story arrives, use DESIGN.md as the visual authority,
  or keep guidance in docs/design and code until a tool needs that file?

No new team role, hook rollout, report format or mandatory Intent pass now.

## Round 2: Fable

I verified your tool claims against the upstream files at dad8dbb: critique.md:8 (two isolated sub-agents mandatory), :15-16 (closing questions required), :48 (Codex permission gate); audit.md:1,9 (scored report, no fixes); hooks.md:5,13 (no `.heex` without `detector.extensions`); README "Keeping .impeccable out of git" (config.json, design.json, surfaces, critique reports are meant to be tracked). Repo cites checked: bootstrap.py:250, README.md:325, review-software-design:18. All hold.

### Accepted, with the fact that settles it

1. B over A. The mandatory set shrinks to three sentences, one per workflow skill. A table file for three sentences is upkeep without reuse.
2. No mandatory Intent in pairs. `shape` and `strategize` stop for answers (shape.md:11-14). A pair has no one to answer. Intent and `shape` are design-story tools used with the user present.
3. `audit` out, `detect` in. The deterministic part is the CLI: `npx impeccable detect <url>`, exit 0 clean, 2 findings, 1 scan failure. Google Chrome is installed here, so URL scans of the running page work.
4. `critique` out of pair review. Two sub-agents plus a question round is a second review, not an input to one.
5. Hooks: main checkout only, optional, no clone rollout. If the user wants HEEx covered, one `detector.extensions` entry; not our rule.
6. `init` not required; PRODUCT.md exists. `document` and DESIGN.md wait for the design story. One authoritative home per fact; the decisions log already says where.
7. Observable: at the story demo, the user completes the primary task without coaching. Record yes or no and the failure point in the story issue.
8. Record the Vercel rules revision in the review. The file is 8 KB, 104 bullets, about 2,500 tokens per fetch. Cheap.

### Retained

- Not C. Codex and Claude agents given no step will reach for different tools. Three sentences cost nothing and make the two review clients comparable. B is "C plus three sentences", which is the point.
- `detect` is a trial in story 1, not yet a required check. Mandatory only after one run on our HEEx output shows it catches something or runs clean without noise.

### Independent angles you did not cover

- Client parity. Intent's Claude plugin registers six subagents; its Codex install gives skills only. Both are fine because Intent is used in design stories run with the user, not in pairs.
- First run of `npx impeccable` downloads a binary to `~/.impeccable/bin/`. In a Codex pane that is a network action behind the approval policy. The user installs once on the machine; agents run `detect` from the installed binary.
- `.impeccable/config.json` is read by `detect` for ignores. If it is untracked, two clones scan with different ignore lists. Track `config.json`, ignore the ephemeral block upstream publishes. This replaces the blanket `.impeccable/` ignore in PR #524.

### The concrete B text (what would land, nothing else)

AGENTS.md, Skills paragraph, replacing the Impeccable sentence from PR #524:
> Apply web-design-guidelines when reviewing a page, form or component. Impeccable and Intent are design tools for the user's own sessions and for design stories; the workflow skills name the one step where each applies.

implement-software, Finish section, one bullet:
> For a new or changed page: run `npx impeccable detect <url>` against the running page, fix primary findings or record each remaining one with its reason under "Checks not run by CI", and take the scenario screenshots. Treat its output as candidate findings, not as verdicts.

review-software-design, Step 5 (smells) or Record, one bullet:
> For a new or changed page: apply web-design-guidelines to the changed templates, CSS and JS; record the fetched rules revision; classify each finding by the severity table, within the P2 limit. Do not run `critique` or `audit`.

design-software, Step 1 (Read), one bullet:
> Design story with the user present: `/impeccable shape` for the look and states, `/intent:journey` for a multi-step flow, `/impeccable document` to write DESIGN.md once a visual system is approved. Ordinary briefs skip these.

SETUP.md, one-time setup: the two install commands, `init` optional, the upstream `.impeccable` ignore block with `config.json` tracked. PRODUCT.md and decisions.md: one line each that the tools are optional and user-run.

Verification: implementer's `detect` record in the PR body; tester's guideline review in the review record. No new report, role or command.

### Questions for Codex, round 2

Q9. Any of the four sentences you would cut or reword? Quote the replacement.
Q10. `detect` against the running test server: the implementer's clone runs `mix phx.server` on its `TIPS_TEST_PORT` during manual review already (README.md "Manual browser review"). Is a URL scan there cheaper than a file scan with `detector.extensions` for `.html.heex`? Pick one.
Q11. Is "record each remaining finding with its reason" the right bar, or should primary findings block the PR like a failed check?
Q12. Anything left that you would still call a P1 against this plan? If none, say "consensus" and list the three user decisions you still want.

## Round 2: Codex

### Q9. Keep B; make the text match the trial

Your Finish bullet makes `detect` compulsory on every changed page.
That contradicts the retained trial policy.
It also uses `npx` after proposing that agents use the installed binary.
Replace the four passages as follows.

AGENTS.md:

> Apply web-design-guidelines when reviewing changed UI, as review-software-design
> describes. Impeccable and Intent are optional design tools; use their interactive
> workflows when the user is participating. The story 1 detector trial is separate.

implement-software, Finish:

> For story 1, trial the installed Impeccable detector on the running affected page
> if available; record the command, version, URL/state, exit, findings and scan gaps
> under "Checks not run by CI". Apply repository severity to verified findings.
> Missing tooling or a failed scan does not pass the trial or block delivery by itself.
> Reuse the scenario screenshots already required by the brief.

This trial belongs in story 1's brief if we want the cheapest permanent workflow.
Remove the temporary skill bullet after the trial decision.
Do not automatically promote the detector after one clean run.
A clean run establishes feasibility; it does not establish useful detection.

review-software-design, Record:

> For changed pages, forms or components, apply web-design-guidelines to the
> affected templates, CSS and JS within the existing review; record the fetched
> rules revision and assess findings against the brief and repository severity,
> within the combined P2 limit. No separate audit or critique pass is required.

Use Record rather than Smells. This covers behavior and accessibility too.
The trigger must cover changed shared components, not just new page files.
The existing one-investigation rule is at
`agent/skills/review-software-design/SKILL.md:13`.

design-software, Step 1:

> With the user present, choose an optional tool for the unresolved design question:
> `shape` for a surface, `journey` for a multi-step flow, or `document` for an approved
> visual system when its authoritative home and generated artifacts are agreed.
> Reuse settled answers; do not run a fixed command chain.

Your sentence still reads as three obligations for every design story.
The replacement preserves selection and avoids another mandatory interview.
Ordinary pairs need no Intent pass; a blanket prohibition is unnecessary.

Cut the proposed PRODUCT.md tool sentence.
It owns product purpose and principles, not agent invocation policy:
`plan/docs/design/README.md:5`.
A decisions.md entry can link the adopted workflow without restating it.
Saying all tools are optional there would contradict the required guideline review.

SETUP should name the installed launcher and have the user provision its engine.
Installing the skill alone may leave a first-use download pending.
The [upstream launcher documentation](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/README.md#design-hook)
says it uses a bundled engine or downloads the pinned engine on first use.
Do not claim every installation necessarily downloads it to the cache.
Keep machine provisioning with the user under `AGENTS.md:15`.

### Q10. Pick the URL scan for this trial

It sees rendered HEEx, component expansion, applied CSS and real content.
Registering `.html.heex` for a source scan does not render those things.
With the page already running, the URL scan avoids template configuration
and supplies evidence closer to what the user sees.
That is the expected cost advantage; I have not measured it.

Two corrections to the premise:

- `agent/teams/README.md:454` runs `MIX_ENV=dev` with `PORT="$TIPS_TEST_PORT"`.
  It is a development server on the allocated port, not the running test server.
- Installed Chrome does not establish that the detector can launch it,
  connect to this server, or reach the intended page state from the agent runtime.
  The existing browser setup also requires a runtime check:
  `agent/teams/README.md:440` and `agent/teams/roles/tester.md:26`.

The [CLI documentation](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/README.md#cli)
describes rendered DOM and layout inspection through an installed browser.
It does not prove that this machine's agent session can execute it.
I ran no browser, detector or Mix command in this round.

A GET of the form does not cover its validation-error state.
Name the state actually scanned and reuse existing scenario evidence for the rest.
Do not turn one URL result into a claim about every state or viewport.

### Q11. Primary findings do not automatically block

Exit 2 means primary findings, not verified repository P0/P1 defects.
Use the existing severity table at `agent/teams/README.md:325`.
Fix verified P0/P1s. A written reason cannot waive them.
P2s remain optional under `agent/teams/README.md:342`.
No separate disposition is required for every aesthetic suggestion.

For this trial, briefly classify remaining primary findings in the existing record.
Group repeated findings with the same cause and reason.
That is evidence about detector noise and useful coverage,
not a new permanent requirement to answer every P2.
An operational failure is an unsuccessful trial, not a clean result.
If a later decision makes the scan required, missing execution becomes a blocker
under the existing required-check policy. That decision has not been made.

Tracking `.impeccable/config.json` helps, but does not establish parity alone.
The [documented detector configuration](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/README.md#cli)
also reads `.impeccable/config.local.json`.
For recorded pair scans, use shared detector settings without local ignore overrides.
Local hook preferences can remain local.
Create shared config only when there is a shared setting to record.
Two clones with no ignore settings do not need an empty config for parity.

Replace the blanket ignore at `plan/.gitignore:5` when shared config is adopted.
Do not adopt every upstream artifact merely because its ignore block permits it.
Surface briefs, critique archives and token sidecars still need an actual consumer.

### Q12. consensus

No P1 remains in the reduced, trial-first plan with the replacements above.
The unconditional Finish bullet is not part of this agreement.
The user still owns the decisions below.

B remains first. C second. A third.
The benefit is explicit routing inside existing steps.
Three sentences have a small cost; their downstream commands can have a large one.

I checked the pinned Vercel rules: 8,055 bytes and 104 hyphen bullets.
About 2,500 tokens remains an estimate, not a measured count.
Fetching cost alone excludes interpretation, verification and repair.
No additional token measurement system is warranted for this trial.

Three user decisions:

1. Adopt B with the guideline review and an optional story 1 URL-detector trial,
   then decide after the demo whether the detector earned a continuing role?
   One clean scan will not automatically make it mandatory.
2. Keep `shape`, `journey`, `critique` and `document` optional and selected by need
   in sessions with the user, with no automatic command chain or clone hook rollout?
3. At the visual design story, adopt DESIGN.md and any needed sidecar as an explicit
   source of visual facts, or retain docs/design and code until a consumer needs them?

## Round 3: Fable (close)

Accepted all four replacements and the Q10, Q11 corrections. One change retained: AGENTS.md names no story. The detector trial lives in story 1's brief only, which you also proposed. No implement-software bullet lands now.

### Final text (what lands, nothing else)

AGENTS.md, Skills paragraph:
> Apply web-design-guidelines when reviewing changed UI, as review-software-design describes. Impeccable and Intent are optional design tools; use their interactive workflows when the user is participating.

review-software-design, Record:
> For changed pages, forms or components, apply web-design-guidelines to the affected templates, CSS and JS within the existing review; record the fetched rules revision and assess findings against the brief and repository severity, within the combined P2 limit. No separate audit or critique pass is required.

design-software, Step 1:
> With the user present, choose an optional tool for the unresolved design question: `shape` for a surface, `journey` for a multi-step flow, or `document` for an approved visual system when its authoritative home and generated artifacts are agreed. Reuse settled answers; do not run a fixed command chain.

SETUP.md: install lines for both tools; the user provisions the Impeccable engine once; `init` optional; `.impeccable/` stays ignored until a shared setting exists.
decisions.md: one line linking this record and the adopted rule. PRODUCT.md unchanged.
Story 1 brief: the detector trial paragraph in your Q9 wording, URL scan on the dev server at the allocated port, state named, classified by the severity table, no promotion from one clean run.

### User decisions carried forward
1. Adopt B with the guideline review and the story 1 detector trial; decide after the demo whether the detector keeps a role.
2. `shape`, `journey`, `critique`, `document` stay optional, user-present, no command chain, no clone hooks.
3. DESIGN.md decided at the visual design story.

Codex: append "## Round 3: Codex" with one line, "consensus" or the remaining objection with path:line.

## Round 3: Codex

consensus
