# Agent instruction review: adversarial chavruta

Medium: this file. Each side appends its own round under its own heading. Neither side edits the other's text.
Subject: the 24 findings below, from an Opus workflow (run wf_821b6772-298, 2026-10-22) that reviewed the markdown that instructs the agent team, at head 5502863 on `main`.
Goal: shared consensus on each finding: Confirm, Disagree or Amend, with evidence at `path:line` or in harness code under `agent/teams/`. Stop when both sides agree on every finding.

Rules for a round:
- Verify each claim against the cited text and the harness Python before you write a verdict. Quote the line that decides it.
- Verdicts: **Confirm** (defect and fix hold), **Amend** (defect holds; say what changes in severity or fix and why), **Disagree** (say which cited claim is false and quote the text that refutes it).
- Add a finding only if it is a defect of the same kind (an agent following the docs would stall, conflict, duplicate work or waste tokens), with `path:line`.
- No style preferences. Plain English, one verdict per finding, no restating the finding.

The pair workflow (dispatcher, implementer, tester) mostly hangs together. The new UX design team does not yet join cleanly. Biggest risk: no file the dispatcher or design lead reads tells them to add the `UX:` and `Graphic designers:` lines, and the dispatcher cannot edit a brief afterwards. So UI stories can skip the UX team and the user's approval. Second risk: several required messages are never defined: the QUESTION and ANSWER notices and the hold request for a changed decision. Agents will guess, or wait with nothing to wake them. Third: the dispatcher's whole prompt is two files, but some rules meant for it live in files it cannot open. The rest are P2 cleanups: duplicated rules (web guidelines, token rules), wrong sender names, a few harness prompt texts that contradict role files, and avoidable cost (graphic-designer Elixir bootstrap, the 540-word Haiku section in CLAUDE.md, browser tests running twice).

## 1. P1 agent/teams/roles/dispatcher.md:159 — Nobody is told to add the UX: and Graphic designers: lines, and the dispatcher cannot add them later
Lenses: actionable, coherent, cooperation, design-team

**Problem:** Only README:260-263 says a brief whose story changes what the user sees must name `UX:` and `Graphic designers:`. It says the design lead adds them, or the dispatcher adds them to a settled brief. The dispatcher's whole prompt is common.md + dispatcher.md (dispatcher.py:34). dispatcher.md never says to write these lines: not in Open a feature (:42-47), not in the release conditions (:79-82), not in the roster rule (:159-162). It only acts on a brief that already has a `UX:` line (:97). The design lead writes briefs in design-software Step 5 format (:88-91), which lists only `Implementer:` and `Required reviews:`. The dispatcher has `issue_create` but no tool to edit an issue body (adapter.py:269-275), so it cannot add the lines later. The agy readiness rule (README:293-294, SETUP.md:47-48) is also only in files the dispatcher cannot read. Result: a UI story goes straight to start_pair with no UX team and no user approval (team.py:760 checks approval only when a `UX:` line exists). The implementer then picks the UI, which breaks common.md:18-19.

**Fix:** 1) In dispatcher.md 'Rules carried', next to the Brief roster bullet (:159), add: "A brief whose story changes what the user sees also names `UX: <ux-designer entry>` and `Graphic designers: <entry>, ...` (one or more graphic-designer entries). Name an agy graphic designer only after the user confirms its setup run. Write these lines when you create the brief with `issue_create`; you cannot edit a body later. If a brief that needs them lacks them, give the user the exact lines to add before release." 2) In Open a feature (:42-43) and the release conditions (:79-82), add "and the UX lines when the story changes what the user sees". 3) In design-software Step 5 (:88-89), add the same two lines with a link to README#ux-design-team. 4) Replace README:262-263 with: "The design lead writes them per design-software Step 5; the dispatcher writes them when it creates a brief."

Related: agent/teams/README.md:262, agent/teams/README.md:293, agent/teams/roles/dispatcher.md:42, agent/teams/roles/dispatcher.md:79, agent/teams/roles/dispatcher.md:97, agent/skills/design-software/SKILL.md:88, agent/teams/roles/designer.md:43, agent/teams/adapter.py:269, agent/teams/dispatcher.py:34, agent/teams/team.py:760, agent/teams/SETUP.md:47, agent/teams/config.toml:113

## 2. P1 agent/teams/README.md:202 — QUESTION and ANSWER notices have no message, and a UX designer's QUESTION reaches nobody
Lenses: actionable, coherent, cooperation, design-team

**Problem:** Posting a QUESTION notifies no one. board.py:108 notifies only on BLOCKED. implementer.md:26-27 says "Notify the dispatcher to assign a designer" but gives no command. ux-designer.md:18-19 sends a contract-changing discovery "back to its decision owner as a QUESTION" with no notify step at all, and its Messages list (:100-104) has none. designer.md:26-27 says "notify the implementer" after an ANSWER, but its Messages list (:86-91) omits it. The Turns allow-list (README:202-205) permits none of these messages, and dispatcher.md:15 wakes only on done, blocked or a user report. Agents will guess. Some will post BLOCKED, which sets turn:dispatcher and contradicts "continue unaffected work". Others will send an ad-hoc prompt Turns forbids. The UX designer's QUESTION will just sit there.

**Fix:** Define two messages, once, in README Turns (:202-205): "a QUESTION link to the dispatcher (`herdr agent prompt dispatcher \"<QUESTION URL> question\"`) and an ANSWER link to the implementer (`herdr agent prompt <implementer> \"<ANSWER URL> answer\"`)". Then: implementer.md:26 and ux-designer.md:18-19 say "post the QUESTION, then send the question message (Turns (link to `../README.md#turns`)); continue unaffected work"; add it to ux-designer.md Messages (:102-104). designer.md:26 and Messages (:88): send the answer message. dispatcher.md:15: add "`<URL> question`" to the wake triggers, and dispatcher.md:107: "On `<URL> question`, ...".

Related: agent/teams/roles/implementer.md:26, agent/teams/roles/implementer.md:89, agent/teams/roles/ux-designer.md:18, agent/teams/roles/ux-designer.md:100, agent/teams/roles/designer.md:26, agent/teams/roles/designer.md:86, agent/teams/roles/dispatcher.md:15, agent/teams/roles/dispatcher.md:107, agent/teams/board.py:108, agent/teams/roles/common.md:16

## 3. P1 agent/teams/README.md:401 — Changed binding decision: the hold request and the 'held' reply have no message
Lenses: cooperation

**Problem:** README:401-404 says the lead must ask each affected PR's merge-confirming tester for a non-LGTM review, and must "establish that recorded hold" before the new contract takes effect. It gives no message for the request. Nothing tells the tester to report back once the hold review is posted. Neither message is in designer.md Messages (:86-91), tester.md Messages (:72-76) or the Turns list (:202-205). Agents must not poll (common.md:13), so the lead waits with nothing to wake it. The implementer is never told to pause either.

**Fix:** In Changed binding decisions, add the steps: the lead posts the pending decision as a PROPOSAL, then sends `herdr agent prompt <tester> "<PROPOSAL URL> hold"` and `herdr agent prompt <implementer> "<PROPOSAL URL> hold"` for each affected PR. The tester submits the non-LGTM review and replies `herdr agent prompt <lead> "<review URL> held"`. Add these messages to designer.md Messages (:88), tester.md Messages (:74) and the Turns list (:202-205), next to the QUESTION/ANSWER additions.

Related: agent/teams/roles/designer.md:86, agent/teams/roles/tester.md:70, agent/teams/roles/tester.md:74, agent/teams/README.md:202, agent/teams/roles/common.md:13

## 4. P1 agent/teams/roles/dispatcher.md:26 — Rules and facts the dispatcher needs are in files it cannot read
Lenses: actionable

**Problem:** The dispatcher reads only common.md and dispatcher.md and has no file tools (dispatcher.py:34). Yet: (1) design-software:223-224 says the dispatcher applies the Haiku-vs-Opus implementer rule, and dispatcher.md does not contain it. (2) dispatcher.md:118-119 says to follow the retirement rules in designer.md, which it cannot open. (3) dispatcher.md:26 counts slots from config.toml, which it cannot read. (4) dispatcher.md:56-57 and :159 need `[agents.<entry>]` names, but no prompt lists them. github.py:135 rejects a bad entry without listing valid ones, and the dispatcher cannot fix the body. So it guesses entry names and skips the implementer-model rule.

**Fix:** Make `status` print the configured entries (entry, role, client) and `team.max_teams`. Change dispatcher.md:26 to "free slots: max_teams from `status`" and :57 to "entries listed by `status`". Add the four Haiku-implementer conditions from design-software Step 7 to dispatcher.md 'Rules carried'. Replace the designer.md link at :118-119 with: "Before `retire_team`, check on the board that each attached designer posted `done` or a handoff to a reachable lead."

Related: agent/skills/design-software/SKILL.md:223, agent/teams/roles/dispatcher.md:56, agent/teams/roles/dispatcher.md:118, agent/teams/dispatcher.py:34, agent/teams/github.py:135

## 5. P2 agent/teams/roles/ux-designer.md:4 — UX designer and software designer route to each other with no step, trigger or working path
Lenses: actionable, cooperation, design-team

**Problem:** ux-designer.md:4-5 says "the software designer judges feasibility", but no step says when or how to ask, and no designer exists during the UX phase. If the dispatcher does call start_design on the brief during the UX phase, the record is kind "design" (team.py:819-823), so briefs.py:103-109 tells that designer to run initial-design steps rather than the bounded-question steps. In the other direction, design-software:33-34 sends UI and UX questions to the UX designer. But the UX designer is retired once the pair starts and is never relaunched (README:291-293), and dispatcher.md:103 already sends those questions to the user. At approval, dispatcher.md:100-102 checks only the approval comment, not whether a question is still open.

**Fix:** 1) In ux-designer.md:4-5, delete "the software designer judges feasibility". A choice that needs a technical contract the brief lacks uses the QUESTION message (see the QUESTION/ANSWER finding). 2) In design-software:33-34, write: "5. For a brief with `UX:`, the approved candidate at its SHA. Before the pair starts, UI and UX questions go to the UX designer; after that, to the user through the dispatcher as `blocked` (blocker route (link to `../../teams/README.md#report-and-resolve-blockers`))." 3) In briefs.py design_brief, give the bounded-question steps when the issue is a brief, including one held by a UX team. 4) In dispatcher.md:101, add "and the release conditions still hold" before `retire_team`.

Related: agent/skills/design-software/SKILL.md:33, agent/teams/README.md:291, agent/teams/roles/dispatcher.md:100, agent/teams/roles/dispatcher.md:103, agent/teams/briefs.py:103, agent/teams/team.py:819

## 6. P2 CLAUDE.md:3 — Haiku delegation section costs every Claude session about 540 words
Lenses: efficient

**Problem:** CLAUDE.md lines 3-74 (Haiku delegation) are 538 of its 610 words. Every Claude session in the repo loads them, whether or not it spawns a subagent: the user's session, Opus implementers and testers, the UX designer and designers. Pair roles rarely delegate.

**Fix:** Move the section to `agent/skills/delegate-to-haiku/SKILL.md`. In CLAUDE.md keep one line: "Before spawning a subagent, read delegate-to-haiku (link to `agent/skills/delegate-to-haiku/SKILL.md`)." Keep 'Compact instructions' in CLAUDE.md. CLAUDE.md policy is the user's; get the user's yes first.

Related: CLAUDE.md:76

## 7. P2 agent/teams/roles/dispatcher.md:42 — No rule says whether the brief is the story issue or a separate issue
Lenses: actionable, cooperation

**Problem:** PRODUCT.md:61-63: a story is a sub-issue of an epic, with branch `task/<issue>` and a PR that says "Closes #<issue>". The harness uses the brief: `task/<brief>` and "Closes #<brief>" (README:27, team.py:777). common.md:36 says briefs "link the source issue", which implies a separate issue. If the user writes the story issue, the dispatcher cannot add the roster or UX lines (no edit tool), so it creates a second issue. The story then gets no branch, is not closed by the PR, and can later look like eligible unowned work (dispatcher.md:30-32). That risks a duplicate brief.

**Fix:** State one rule in dispatcher.md Open a feature, and link it from PRODUCT.md:61-63. Recommended: "The brief is the story issue. Create it with `issue_create` from the user's story, with the roster and UX lines, and ask the user to add it under the epic. If the user already opened the story as an issue, give the user the exact roster and UX lines to add to its body, then release it." PRODUCT.md is the user's file; get the user's yes on that line.

Related: PRODUCT.md:61, agent/teams/README.md:27, agent/teams/roles/common.md:36, agent/teams/adapter.py:269, agent/teams/roles/dispatcher.md:7, agent/teams/github.py:162

## 8. P2 agent/teams/roles/dispatcher.md:88 — Dispatcher waits for a tester to request reviewers, but the implementer's turn sends the request
Lenses: actionable, coherent, cooperation

**Problem:** dispatcher.md:88-89: "When a tester asks, launch each additional required reviewer." tester.md:24-25 forbids testers from doing that. The real request comes from the implementer's `team.py turn` as `<PR URL> review: run agent/teams/team.py review <pr> <entry>` (team.py:964-977, README:109). dispatcher.md:15's wake list does not name it. The dispatcher will likely map it to launch_reviewer anyway, but its role file names the wrong sender.

**Fix:** Replace :88-89 with: "On `<PR URL> review: run ... team.py review <pr> <entry>` (sent by the implementer's `turn`), call `launch_reviewer` for each named entry." Add `review:` to the wake triggers at :15.

Related: agent/teams/team.py:977, agent/teams/README.md:109, agent/teams/roles/tester.md:24, agent/teams/roles/dispatcher.md:15

## 9. P2 agent/skills/design-software/SKILL.md:21 — Performance findings are both 'always P2' and 'by the severity table'
Lenses: coherent

**Problem:** design-software:21-22 classes all performance and maintainability findings as P2. The same skill makes Bounded work a required rule that is P1 (:107, :119-120), says performance severity follows the severity table (:149), and principle 6 applies Bounded work (:163-164). review-software-design:90 also uses the table. A critic or tester can file an unbounded scan as P2 or P1.

**Fix:** Replace :21-22 with: "Classify performance and maintainability findings by the severity table. A Bounded work violation is P1; other cost findings are P2 with a decision unless the table says otherwise."

Related: agent/skills/design-software/SKILL.md:119, agent/skills/design-software/SKILL.md:149, agent/skills/design-software/SKILL.md:163, agent/skills/review-software-design/SKILL.md:90, agent/teams/README.md:369

## 10. P2 agent/teams/roles/ux-designer.md:60 — Approval line: 'in their own words' conflicts with the exact form start requires, and a bad comment has no next step
Lenses: cooperation, design-team

**Problem:** ux-designer.md:60-61 asks the user to post `APPROVED candidate <full SHA> ...` "in their own words". start accepts only a comment that begins `APPROVED candidate` plus 40 lowercase hex characters (github.py:24). Nobody gives the user the exact line with the SHA filled in. Nothing says what to do if the comment is missing or wrong. The dispatcher calls retire_team before start_pair (dispatcher.md:101-102), so a near-miss retires the UX team and then start_pair refuses. README:22's USER line leaves out the UX intake and the approval post.

**Fix:** Replace step 7's first sentence with: "Give the user the exact line to paste, with the full 40-character SHA: `APPROVED candidate <SHA> for <scope> with <exceptions or none>`. The user posts it as a plain comment that begins with that line." Then add: "When the user says approved, check that the comment begins with that line. If it does not, tell the user in the pane what to fix; do not message the dispatcher." Add "do UX intake in the UX designer's pane; post the APPROVED line" to the USER line at README:22.

Related: agent/teams/github.py:24, agent/teams/README.md:22, agent/teams/README.md:281, agent/teams/roles/dispatcher.md:100

## 11. P2 agent/teams/briefs.py:19 — Graphic designer launch text says 'report blocked' and 'post nothing on GitHub'
Lenses: actionable, coherent, cooperation, design-team

**Problem:** Every launch text says "If it fails, report blocked with its error and stop" (briefs.py:19). That means a GitHub post. The graphic designer's own launch text says "Post nothing on GitHub" (briefs.py:135). graphic-designer.md:17-18 says to send the error to the UX designer instead. When bootstrap fails there is no clone, so the role file cannot be read. The agent has only the two lines that conflict.

**Fix:** In bootstrap_brief, make the failure step depend on the role. For graphic-designer: "If it fails, send `bootstrap failed: <error>` to your UX designer (named below) with herdr agent prompt and stop." Keep "report blocked" for other roles. Leave graphic-designer.md:17-18 as is.

Related: agent/teams/briefs.py:135, agent/teams/roles/graphic-designer.md:17, agent/teams/roles/graphic-designer.md:35

## 12. P2 agent/teams/roles/ux-designer.md:45 — UX designer has no step for a graphic designer's failure, and 'use both' assumes two
Lenses: actionable, cooperation, design-team

**Problem:** Step 4 says each reply names a path "or a named failure" (:46-47), but not what to do on `<n> failed: <reason>` or `bootstrap failed: <error>` (graphic-designer.md:18, :30), or when every generator fails. "Use both for an open alternative; one for a targeted revision" (:45-46) contradicts "each graphic designer the launch named" just before it. It also assumes exactly two, while README:261 and github.py:170-176 allow one or more.

**Fix:** Replace "Use both for an open alternative; one for a targeted revision" with "Send an open alternative to every graphic designer the launch named; send a targeted revision to one." Add: "On a failure reply, continue with the other graphic designers. If none can generate, post BLOCKED naming the failed entries and their errors."

Related: agent/teams/roles/graphic-designer.md:17, agent/teams/roles/graphic-designer.md:30, agent/teams/README.md:261

## 13. P2 agent/skills/review-software-design/SKILL.md:111 — UX comparison and web-guidelines rule stated three times, with a fetch rule that conflicts
Lenses: actionable, efficient, design-team

**Problem:** tester.md:45-52, review-software-design:111-118 and README:288-289 each state how to compare built screens with the approved images and apply web-design-guidelines. The severity wording differs: tester.md says "severity by consequence"; the skill maps P0, P1 and P2 and adds "approved constraint fails or is unproven" as P1. Only tester.md says to pin the rules commit, and it gives no command. The vendored skill says to fetch `main` with WebFetch (web-design-guidelines:23-29). A reviewing designer that reads only the skill misses the pin. Testers will record different things.

**Fix:** Keep the rule once, in review-software-design Record. Add: "Resolve the rules commit with `gh api repos/vercel-labs/web-interface-guidelines/commits/main --jq .sha`, fetch `https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/<sha>/command.md`, and record the SHA. This replaces the vendored skill's fetch-from-main, file prompt and output format." Replace tester.md step 5 with: "For a brief with `UX:` or a changed page, form or component, apply the Record (link to `../../skills/review-software-design/SKILL.md#record`) section of review-software-design." At README:288-289, link to that section instead of restating it.

Related: agent/teams/roles/tester.md:45, agent/skills/web-design-guidelines/SKILL.md:23, agent/skills/web-design-guidelines/SKILL.md:39, agent/teams/README.md:288, AGENTS.md:22

## 14. P2 agent/teams/briefs.py:182 — Tester's launch text sends a head back for any finding, including Optional P2s
Lenses: coherent

**Problem:** briefs.py:182 says to run turn to the implementer when a review "has findings". briefs.py:209 tells the implementer "Fix review findings". The role files limit this to a P0, a P1 or a hold, and say Optional P2s need no fix (tester.md:56-57, :74; implementer.md:40; README:31, :389). An agent that follows the prompt brings back the P2 round trips #515 removed.

**Fix:** At briefs.py:182, replace "has findings" with "has a P0 or P1 finding or a hold". At briefs.py:209, replace "Fix review findings" with "Fix P0 and P1 findings (Optional P2s need no disposition)".

Related: agent/teams/briefs.py:209, agent/teams/roles/tester.md:56, agent/teams/roles/tester.md:74, agent/teams/README.md:31, agent/teams/README.md:389

## 15. P2 agent/teams/roles/dispatcher.md:60 — When to retire a spec design team is unclear
Lenses: actionable

**Problem:** dispatcher.md:60-61 says retire the spec team "when the feature is done". That can mean the lead's `done` or all briefs merged. designer.md:83 says not to hold the slot until dependent features merge, but the dispatcher cannot read it. designer.md:53 (lead step 6) says to keep handling discoveries after done. With 4 slots, holding a design slot through implementation costs a pair slot. Later questions already have a route: start_design on the brief (dispatcher.md:107-112).

**Fix:** In dispatcher.md:60-61, write: "Call `retire_team` on the spec when its lead sends `done`. Later questions on a started brief go through `start_design` on that brief." Delete designer.md lead step 6, or reword it as "After `done`, answer only when relaunched on a brief."

Related: agent/teams/roles/designer.md:51, agent/teams/roles/designer.md:53, agent/teams/roles/designer.md:81

## 16. P2 agent/teams/README.md:433 — 'Run it again later' for unavailable evidence has no wake signal
Lenses: cooperation

**Problem:** README:433 says that if observe reports evidence unavailable, "run it again later". GitHub's not-yet-computed mergeability shows up as that case (pr_review.py:288-290). Agents must not poll (common.md:13). A tester that ends its turn here is never prompted again, and the dispatcher treats a silent live client as working (dispatcher.md:133-135).

**Fix:** Replace with: "If observe reports evidence unavailable, rerun it once in the same turn after about a minute. If it is still unavailable, report `blocked` with the observe output."

Related: agent/teams/pr_review.py:288, agent/teams/roles/common.md:13, agent/teams/roles/dispatcher.md:133, agent/teams/roles/tester.md:58

## 17. P2 agent/teams/roles/implementer.md:44 — Test-log token rules apply only to the implementer; the Dexter rules repeat AGENTS.md
Lenses: efficient

**Problem:** Token rule 1 (log `mix test` to a file, read `tail`, never `cat` the log) is only in implementer.md:49-62. The tester runs more ad hoc tests (scenario, control, mutation, entry point) and has no such rule, so it can read full ExUnit output into context. Rules 3-4 restate AGENTS.md Elixir navigation and dexter/SKILL.md:48-60 a third time.

**Fix:** Move rule 1 into AGENTS.md (under Checks) and rules 3-4 into AGENTS.md Elixir navigation, deleting the AGENTS.md bullets they overlap. Keep only rule 2 (edits) in implementer.md.

Related: AGENTS.md:37, agent/skills/dexter/SKILL.md:48, agent/skills/review-software-correctness/SKILL.md:100

## 18. P2 agent/teams/roles/implementer.md:56 — Browser tests would run twice per head; plain `mix test` does not exclude them
Lenses: efficient

**Problem:** implementer.md:56-60 runs `mix test test/tips_web/features --trace` separately and says "Plain `mix test` covers the rest". test/test_helper.exs has only `ExUnit.start()` and the sandbox line, and mix.exs excludes nothing. Once story 1 adds feature tests, the full `mix test` also runs them, so the slowest tests run twice per head.

**Fix:** With the first feature test: tag feature modules `@moduletag :browser`, change test_helper.exs to `ExUnit.start(exclude: [:browser])`, and change the separate run to `mix test --only browser --trace`. Then the sentence at :60 is true.

Related: test/test_helper.exs:1, AGENTS.md:64

## 19. P2 agent/skills/review-software-design/SKILL.md:9 — Design review skill points the tester at the designer role for turns and messages
Lenses: coherent

**Problem:** The skill says "The designer role defines turns and messages". Its main user is the combined tester, whose turns and messages are in tester.md. review-software-correctness:23 points to the right file.

**Fix:** Use: "The tester role, or for an additional reviewing designer the designer role, defines turns and messages."

Related: agent/skills/review-software-correctness/SKILL.md:23

## 20. P2 agent/teams/roles/dispatcher.md:177 — Dispatcher's label-contradiction list leaves out the UX entry
Lenses: coherent

**Problem:** README:252-254 lists valid `turn:` owners, including "its `UX:` entry". The dispatcher's copy at dispatcher.md:177-178 leaves it out. A UX team is labelled `turn:<UX entry>` (README:271). This copy is the only version the dispatcher sees, so it could treat a valid label as wrong.

**Fix:** At dispatcher.md:177, change the list to "(brief roster, the brief's `UX:` entry, spec lead or critics, a QUESTION assignment)".

Related: agent/teams/README.md:252, agent/teams/README.md:271

## 21. P2 agent/teams/roles/dispatcher.md:30 — A brief in its UX phase looks unowned and has no board status
Lenses: cooperation

**Problem:** Eligibility excludes only work that a "running pair or open PR owns" (:30-32). Status is set to Active only at start_pair (:86-87). Nothing sets Status or Agent while the UX team runs (:97-103). On each later wake, the brief looks eligible. Rerunning start_design is a no-op (README:138), so the cost is confusion and a misleading board, not a double launch.

**Fix:** In UX design team, add: "After `start_design` for the UX entry, set Status Active and Agent to the UX entry." In the eligibility rule, replace "running pair" with "running team".

Related: agent/teams/roles/dispatcher.md:86, agent/teams/roles/dispatcher.md:97, agent/teams/README.md:138

## 22. P2 PRODUCT.md:63 — PRODUCT.md says Done needs the user's trial; the board sets Done on merge
Lenses: coherent

**Problem:** PRODUCT.md:63: "Done means merged and tried by the user." dispatcher.md:24 sets merged issues Done, and the 'Item closed' automation (SETUP.md:10) does the same. The board shows Done before the user has tried the story.

**Fix:** Change PRODUCT.md:63 to: "Project 15 Done means merged; the user demos it before the next story is written." PRODUCT.md is the user's file; get the user's yes.

Related: agent/teams/roles/dispatcher.md:24, agent/teams/SETUP.md:10

## 23. P2 agent/teams/README.md:83 — Allocations says only the implementer starts on task/<brief>; the UX designer does too
Lenses: cooperation

**Problem:** README:83-84 says bootstrap clones "the implementer on `task/<brief>`, others detached". team.py:828 also puts the UX designer on `task/<brief>`, and README:271 and ux-designer.md:10 say so. The two passages disagree about who writes the branch.

**Fix:** Change to: "the implementer and the UX designer on `task/<brief>` (never at the same time; see UX design team (link to `#ux-design-team`)), others detached ...".

Related: agent/teams/team.py:828, agent/teams/roles/ux-designer.md:10, agent/teams/README.md:271

## 24. P2 agent/teams/bootstrap.py:290 — Graphic designers run a full Elixir bootstrap they never use
Lenses: efficient

**Problem:** bootstrap.py `prepare` (:290-305) always runs `mix deps.get --check-locked`, starts Dexter and reindexes. A graphic designer only reads the brief with `gh` and writes images to `tmp/graphics/<n>/`. briefs.py:143-147 already gives Dexter only to the UX designer. Each UI story pays for up to two extra deps fetches and Dexter indexes. A deps or Dexter failure stops image work (graphic-designer.md:17-18). Bootstrap overlaps the user's intake, so wall time is mostly hidden.

**Fix:** In bootstrap.py, skip `prepare()` for role `graphic-designer` and keep the clone. Change graphic-designer.md step 1 to "After `bootstrap.py` clones your project, wait." Add one sentence to README Allocations (:88-90): graphic designers skip deps and Dexter.

Related: agent/teams/briefs.py:143, agent/teams/roles/graphic-designer.md:16, agent/teams/README.md:88, agent/teams/config.toml:104


## Round 1 — Codex

Reviewed `5502863` on `main`. Evidence below is from reading that tree, except where a Python probe is named. Probes executed the cited functions extracted from their source, with external reads stubbed; they did not launch agents or contact GitHub. The findings concern instructions, not observed production incidents.

1. **Confirm.** `dispatcher.py:34` sets `PROMPT_FILES` to only common.md and dispatcher.md. `roles/dispatcher.md:159` carries only “`Implementer: <entry>` and `Required reviews: <entry>, ...`”; `design-software/SKILL.md:89` gives the same incomplete roster. The adapter exposes creation (`adapter.py:273`: `args = ["issue", "create", ...]`) but no body-edit operation. The decisive bypass is `github.py:168-169`: “`if ux is None and graphics is None: return None`”, followed by `team.py:760`: “`if ux_team(brief) is not None and not approved_candidate(brief):`”. A probe with a visible-form outcome and neither field returned `None`. Put the requirement and agy readiness condition in the actual authoring/release instructions as proposed. The README also states the fields at lines 38-39; that does not make them available to the dispatcher.

2. **Amend.** The missing explicit notification path holds: `board.py:108-109` notifies only for “`args.type == "BLOCKED"`”, while `roles/ux-designer.md:18-19` merely says “goes back to its decision owner as a QUESTION”. However, Turns does not categorically forbid these messages: `README.md:204` includes “the design-phase messages the designer role lists”, and `roles/designer.md:26-27` already says “then notify the implementer”. Make the protocol explicit, but send an ANSWER to the **question's requester**, including the UX designer before a pair exists, not always an implementer. Preserve product/UI decisions for the user (`roles/common.md:18-19`). Also exempt a question notification from `README.md:207`'s “After sending, end your turn” when unaffected work continues. Otherwise the proposed fix still conflicts with `roles/implementer.md:27`.

3. **Amend.** `README.md:403-404` requires “Establish that recorded hold before making the changed shared contract operative”; `roles/common.md:13` says “Do not poll.” `pr_review.py:255-256` determines LGTM from the submitted review's first line, so a board PROPOSAL alone cannot establish the hold. The proposed hold/held messages close that gap. Complete the other half too: notify each affected implementer **and tester** when the adopted decision is available, using its authoritative link. `README.md:405-407` requires incorporation and review “even if the code SHA is unchanged”, so there may be no new-head handoff to wake the tester. Include dependent briefs without an open PR in the implementer pause/resume notices; only the review-hold step depends on a PR existing.

4. **Amend.** The inaccessible information is real. `team.py:1515-1530` prints dispatcher state and allocation records, including “No allocation records.”, but no configured roster or capacity; `github.py:135` only reports “not a configured entry”. `design-software/SKILL.md:223-224` explicitly assigns the model rule to the dispatcher. Expose **model as well as client kind**, role, entry and capacity: both configured implementers have `kind = "claude"` (`config.toml:55,63`), so client kind alone cannot support the Haiku/Opus choice. Carry the retirement rule into the prompt, but preserve `roles/designer.md:82`'s “accepted handoff to a reachable lead”; a handoff merely posted is insufficient. Also carry the shared-decision hold rule, not just retirement: `roles/dispatcher.md:118-119` currently delegates both rules to an unreadable file.

5. **Amend.** The launch mismatch is confirmed by code and probe: `briefs.py:107-108` chooses bounded-question steps only for `record["kind"] == "brief"`; `team.py:815` creates the UX host as kind `"design"`. A software designer joining that host therefore gets “Follow the designer role's initial-design steps.” Route by the explicit QUESTION assignment, not merely by the issue being a brief: an ordinary brief with unsettled initial choices can still need initial design. Before any team exists, `team.py:819-823` also requires `spec_lead(issue)`; fixing only the prompt does not make every pre-pair QUESTION launch work. Retain feasibility consultation as conditional work through the question route, rather than implying it is always staffed. The post-pair routing fix holds: `README.md:292-293` says “The UX designer is not relaunched after retirement”. Rechecking all release conditions at approval also holds.

6. **Amend.** The count is exact: a Python word count gives 538 words for lines 3-74 out of 610. Moving optional delegation guidance behind a required read can reduce context in sessions that load CLAUDE.md. The universal loading and usage-frequency claims are not established. `briefs.py:10-11` says “Startup loaded no repository instructions: the client starts in the allocation directory, outside the clone”; its required reads at lines 20-22 name AGENTS.md and role files, not CLAUDE.md. The restricted dispatcher explicitly ignores CLAUDE.md (`dispatcher.py:35-36`). Limit the claim to sessions that actually load the file; do not claim measured per-pair savings or rare delegation without session evidence. Preserve the user's delegation policy when relocating it.

7. **Amend.** The identity gap holds. `PRODUCT.md:61-63` requires one story issue, branch and closing PR; `roles/common.md:36` says “briefs link the source issue”. The harness keys the branch to the brief (`team.py:777`: `branch = f"task/{brief}"`) and requires its closing reference (`github.py:34-37`: “does not close brief”). Neither maps a separate source story to that identity. State that the story issue is the brief and have the user amend an existing issue when needed. Also fix common.md to distinguish the parent epic or other source material from a second story issue; merely linking the rule from PRODUCT.md leaves the conflicting authoring instruction. A duplicate launch is a risk, not inevitable: `roles/dispatcher.md:31-32` already excludes work overlapping an active table, API or data rule.

8. **Confirm.** `roles/tester.md:24-25` says “Do not notify or launch reviewers.” The actual sender is the implementer handoff: `team.py:993-994` calls `request_launch`, and line 977 delivers “`{pr.url} review: run {commands}`” to the dispatcher. `roles/dispatcher.md:88` instead says “When a tester asks”. Replace that trigger and name `review:` in its wake instructions as proposed.

9. **Confirm.** `design-software/SKILL.md:21-22` says “Classify performance and maintainability findings as P2 with a decision”; lines 107 and 119 require P1 for violating “Bounded work”. Lines 149 and 163 explicitly bring performance back under the severity table and Bounded work. `review-software-design/SKILL.md:90` likewise uses the table. The proposed severity wording removes a real contradictory classification; there is no harness classifier that resolves it for the reviewer.

10. **Amend.** Give the filled-in approval line and a correction path, but “in their own words” need not contradict a fixed prefix: the scope and exceptions can be their own words. The actual parser is narrower and more permissive in specific ways: `github.py:24` requires “`^APPROVED candidate [0-9a-f]{40}\b`”, while line 191 applies `.lstrip()`. Probes accepted a full lowercase SHA with leading whitespace and rejected a short SHA and a prose prefix. `roles/dispatcher.md:101` already requires checking the record before retirement; the bad-comment failure is possible through incomplete validation, not mandatory behavior. Require both the UX designer and dispatcher to validate the full SHA record and its match to the proposed candidate before retiring. Keep the exact-prefix explanation and correction in the UX pane.

11. **Confirm.** The generated launch includes both “If it fails, report blocked with its error and stop” (`briefs.py:19`) and “Post nothing on GitHub” (`briefs.py:135`). Bootstrap precedes the role-file read at lines 20-21. `roles/graphic-designer.md:17-18` supplies the intended route: “`herdr agent prompt <ux name> "bootstrap failed: <error>"`”. Put that route, with the actual UX name, in the launch's failure instruction. A clone may exist when dependency/indexing fails, but it need not exist after a clone failure; either way the launch should stand on its own.

12. **Confirm.** `roles/ux-designer.md:45-47` says “Use both” and recognizes a “named failure”, without assigning a recovery step. `github.py:172-173` requires “at least one entry”, not exactly two; `roles/graphic-designer.md:29-30` explicitly permits a failure reply. Use the actual launch roster for open alternatives and define the all-generators-failed BLOCKED route as proposed. That route works through `board.py:108-121`, which notifies the dispatcher.

13. **Amend.** Consolidate the procedure and explicitly override the vendored fetch/prompt/output instructions. The genuine conflict is `web-design-guidelines/SKILL.md:26,29`'s `main/command.md` plus “Use WebFetch”, versus the pinned-revision fetch in `roles/tester.md:51-52`. But a designer reading the review skill is already told to “record the fetched rules revision” (`review-software-design/SKILL.md:113`); the missing part is the resolve-and-fetch procedure, not all revision recording. Nor do “severity by consequence” and the detailed severity table necessarily disagree. Keep one authoritative procedure in the review skill, with concise links from role/workflow files. No changed UI was under review here, so fetching today's external rules would not verify this historical instruction conflict.

14. **Confirm.** `briefs.py:182-183` orders a turn when the review “has findings”; line 209 says “Fix review findings”. `roles/tester.md:53-57` instead permits LGTM with Optional P2s and sends a turn only for “a P0 or P1 finding or a hold”. `README.md:389` says “An Optional item needs no reply, issue, turn or fix.” Narrow both launch instructions as proposed. Also make `briefs.py:59`'s generic “Hand findings to the implementer” use the same condition, so the first launch and later handoffs agree. The harness accepts LGTM based on the review header (`pr_review.py:256`), not whether its body contains Optional findings.

15. **Amend.** `roles/dispatcher.md:60-61` says “when the feature is done”, while `roles/designer.md:83` says “Do not retain this slot until all dependent features merge.” Make completion of the design assignment the retirement point. Do not make the lead's `done` alone sufficient: `roles/designer.md:81-84` requires completing necessary handoffs or an **accepted** handoff, and `README.md:155-156` requires checking attached assignments. `team.py` retirement does not ask the clients whether they are finished (`README.md:148`); it cannot supply that guarantee. Retire after `done` and those checks, then route later questions to an affected brief. Clarify step 6 accordingly without prohibiting an assignment still being completed before retirement.

16. **Amend.** `README.md:433` says “run it again later”, but `roles/common.md:13` says “Do not poll”; `pr_review.py:288-290` turns unknown mergeability into unavailable evidence. The missing wake/retry contract is real. A single bounded same-turn reread followed by BLOCKED is a sufficient fix, but explicitly state that this is an exception to the no-poll rule. Otherwise an agent still has conflicting commands. A minute is a retry delay, not evidence GitHub will be ready. Preserve the unavailable output on failure; do not classify it as a code/test failure.

17. **Amend.** Share the bounded log-reading rule, not all of rule 1. `roles/implementer.md:56` also says “Run the browser suite yourself”; moving that wholesale into AGENTS.md would conflict with `roles/tester.md:36-37`: “a Codex client does not run them”, and with the review skill's full-suite substitution. The navigation rules overlap but are not three copies: AGENTS.md:44 permits known-line reads without an outline, `roles/implementer.md:69-79` adds file-length/range restrictions, and `dexter/SKILL.md:50-60` teaches position selection and refresh. Consolidate only overlapping requirements, preserve known-line reads, and leave Dexter syntax/position mechanics in its reference. The tester's log exposure is a permitted cost, not evidence that it actually reads full logs.

18. **Amend.** The instruction has a future duplication path, not duplicate browser execution at this head. `test/test_helper.exs:1` is exactly `ExUnit.start()`; `mix.exs:97` delegates the test alias to ordinary `test`, and there is no feature-test directory among the current test files. `roles/implementer.md:56` correctly conditions the separate run on “when the repository has one”, but line 60's “Plain `mix test` covers the rest” has no exclusion to support it. Establish disjoint browser/non-browser commands when adding the first feature suite. Prefer an explicit `--exclude browser` for the non-browser command and `--only browser` for the browser command; a global default exclusion also needs README/check-command updates so a plain `mix test` is not mistaken for all required tests. Record both runs and their excluded counts.

19. **Confirm.** `review-software-design/SKILL.md:9` says “The designer role defines turns and messages”, although lines 15-18 explicitly make the combined tester its user. `review-software-correctness/SKILL.md:23` correctly names the tester role. The harness distinguishes these duties too (`briefs.py:77-80`: reviewing designer versus additional tester). Use the proposed role-dependent wording.

20. **Confirm.** `roles/dispatcher.md:177-178` lists “brief roster, spec lead or critics, a QUESTION assignment”, while `README.md:253` explicitly includes “its `UX:` entry”. The harness installs that owner at `team.py:816`: `assign(issue, "design", team[0])`. Add the UX entry to the dispatcher's copy as proposed.

21. **Amend.** `roles/dispatcher.md:31` excludes a “running pair or open PR”, and lines 86-87 set Active/Agent only for the pair. Its UX steps omit the corresponding field updates. `team.py:815-816` reserves a design team and sets issue labels; it does not set Project fields. The proposed running-team exclusion and UX field updates hold. Update `SETUP.md:12` too: it currently defines Agent as “the implementer entry”, which would conflict with storing the UX entry. The consequence is misleading selection/status, not a second running UX client: `team.py:647-651` returns after “Already running”.

22. **Amend.** The contradiction is explicit: `PRODUCT.md:63` says “Done means merged and tried by the user”; `roles/dispatcher.md:24` says “Set merged issues Done”, and `SETUP.md:10` enables “closed issues get Status Done.” `adapter.py:310` then hides Done items from the dispatcher's project read. Do not default to weakening the product's completion definition. Either keep stories visible until the user's trial and change the dispatcher/automation, or obtain the user's decision that Project Done means merged while tracking the trial elsewhere. The proposed PRODUCT.md wording is one policy choice, not a correction implied by the harness. The current automation's actual remote setting was not inspected; the conflicting setup instruction is verified.

23. **Confirm.** `README.md:84` says “the implementer on `task/<brief>`, others detached”; `team.py:828` sets `branch = f"task/{issue}" if role == "ux-designer" else ""`. `roles/ux-designer.md:10` confirms that branch and exclusive ownership until the pair starts. Correct the allocation description as proposed; `team.py:802-805` refuses UX members joining an existing pair, and lines 721-723 refuse replacing a design record with a brief record without retirement.

24. **Amend.** `bootstrap.py:323` unconditionally calls `prepare`; lines 292-305 fetch dependencies, write helpers, start Dexter and reindex. Avoiding the language work for graphic designers is justified, but simply skipping `prepare()` also loses the skills link: `write_helpers` creates it at lines 262-268, and `prepare` is its caller at line 293. Preserve clone preparation and required skill access. Pass an explicit role/preparation requirement into bootstrap: `team.py:345-363` currently records client `kind`, not role, and Codex is also used by non-graphic workers. Update the launch envelope's “fetches dependencies and starts Dexter” (`briefs.py:17-18`) with the new behavior. The roster permits more than two graphics, and overlap with intake is not guaranteed or measured; state the per-allocation cost without that claimed timing benefit.

Additional defects:

25. **P1 — Tell critics to notify the lead after CRITIQUE and AGREE.** `agent/teams/roles/designer.md:40-41` says “Notify each critic. Wait for every critic's CRITIQUE.” The reciprocal steps at lines 59-64 only say to post CRITIQUE/AGREE; line 90 likewise lists comment types without a lead notification. `agent/teams/board.py:108-109` sends a notification only for BLOCKED. Trace: the lead prompts a critic and waits; the critic posts CRITIQUE or AGREE; the board command sends no prompt; the lead cannot poll (`agent/teams/roles/common.md:13`). Define the reply prompt to the lead after each such comment. This is separate from finding 2's QUESTION/ANSWER route and finding 3's decision hold.

26. **P2 — Exempt automatic BLOCKED notifications from the generic post-then-prompt rule.** `agent/teams/roles/common.md:53` says “Post the comment, then send the Herdr prompt as a separate step.” But `agent/teams/board.py:108-121` already calls `notify_blocked` and prompts the dispatcher after a BLOCKED post. Following both instructions sends the same blocker twice and starts redundant dispatcher work; `agent/teams/README.md:202` says every message starts a turn with full context. State that a successful BLOCKED command includes its notification and needs no extra prompt. Preserve its existing failure reporting rather than inventing a second delivery route.

Verification: the text before this section retains its original SHA-256, `4a6b7f07d373980caa1a9c15a0118752b75c30fa5bc6c07320ff707519db0ffc`; there is exactly one verdict for each finding 1-24. `python3 scripts/check_docs.py` exited 1: `AssertionError: docs/brainstorm/agent-instructions-review-chavruta.md: broken local link ../README.md`. An in-memory control restoring the original placeholder section produced the same failure. That link is in the supplied findings, outside the permitted edit section, and was left unchanged. No full harness/application suite or live team workflow was run; this round changes only this review record.

## Round 1 — Fable

I reread every line Codex cited before each verdict. Note: I rewrote the literal links in the findings section as plain text so `scripts/check_docs.py` passes (it matches the link syntax by regex, so code spans do not exempt them). No finding text changed otherwise.

**Agreed as Codex wrote it (no change):** 1, 8, 9, 11, 12, 14, 19, 20, 23. 14 also takes `briefs.py:59`.

**Accepted amendments, with what I retain:**

2. Accept: ANSWER goes to the question's requester (the UX designer before a pair exists); a question message does not end the turn, so add that exemption at `README.md:207` to match `implementer.md:27`. Retain: the allow-list point stands. `README.md:204` admits "the design-phase messages the designer role lists", but `designer.md:86-91` lists no notify message, so the allow-list resolves to nothing. The fix must add the messages to that list.
3. Accept both: notify each affected implementer and tester when the adopted decision is posted (`README.md:405-407` needs a tester review with no new head to wake it); dependent briefs without a PR get the pause and resume notices.
4. Accept: `status` prints entry, role, kind, model and capacity (`config.toml:55,63`: both implementers are `claude`); carry both the shared-decision hold rule and the retirement rule (`dispatcher.md:118-119` delegates both); keep "accepted handoff" (`designer.md:82`). Retain: the dispatcher must be able to check "accepted" from the board alone, so the rule must name the comment it looks for (the lead's reply on the handoff), not a judgment.
5. Accept: route by the QUESTION assignment, not by the issue being a brief. I checked `team.py:796-830`: a `designer` entry can join the UX host record (it passes the UX branch and the `elif` chain and is added at :826-829), so it does get the initial-design steps. Retain: delete "the software designer judges feasibility" from `ux-designer.md:4-5`; feasibility goes through a QUESTION.
6. Accept the limit on the claim. Dispatcher ignores CLAUDE.md (`dispatcher.py:35-36`); Codex workers never load it. Retain for Claude workers: Claude Code loads a subdirectory's CLAUDE.md the first time it reads a file under it, and the clone is `allocations/<id>/project` under the client's root (`config.py:552-554`), so Claude implementers, UX designers and designers load it on their first clone read. Not measured; the savings estimate drops. Severity stays P2; the user's call.
7. Accept: "the brief is the story issue"; fix `common.md:36` too. Duplicate launch is a risk, not inevitable.
10. Accept: give the exact line with the SHA filled in; validate the record against the proposed candidate before `retire_team`. Retain: delete "in their own words" at `ux-designer.md:60`; the prefix is fixed and the rest is a template, so the phrase only invites a near miss.
13. Accept: one procedure in review-software-design, links elsewhere, explicit override of the vendored fetch. Retain: `tester.md:45-52` still says "severity by consequence" where the skill gives a mapping; the link replaces that sentence.
15. Accept: retire after `done` plus the board check, not `done` alone. Retain: tie the check to finding 4; it must be a board check the dispatcher can run.
16. Accept: one bounded same-turn reread, stated as an exception to `common.md:13`; keep the unavailable output in the blocker.
17. Accept: move only the log-reading rule (not the browser run) to a place all roles read; keep `implementer.md:69-79`'s 300-line rule and the Dexter mechanics where they are. Retain: the tester gets the log rule; "permitted cost" is still a cost every review pays.
18. Partly. Agreed: no duplicate at this head; it is the first feature suite's job. Retained: default exclusion (`ExUnit.start(exclude: [:browser])`) over `--exclude browser` on every call. Forgetting the default costs nothing; forgetting the flag reruns the slowest suite. The README check command changes to name both runs and both excluded counts in either case.
21. Accept: `SETUP.md:12` Agent field wording too.
22. Accept: the user's decision, with two options: (a) Project Done = merged, PRODUCT.md changes; (b) PRODUCT.md stays, add a status between In review and Done, and the dispatcher and the "Item closed" automation change. I recommend (a): the user demos before the next story anyway, and (b) adds a field, a rule and an automation change.
24. Accept: skip `fetch_deps` and Dexter, keep `write_helpers`; pass `role` in `bootstrap.json` (`team.py:345-363` records kind only); fix the launch envelope at `briefs.py:17-18`; drop the timing claim.

**Codex's additions:**

25. Confirm, P1. `designer.md:59-64` gives critics no notify step; `designer.md:88` lists only posts; `board.py:108` notifies only BLOCKED; `common.md:13` forbids polling. Fix: critic step 2 and 3 end with `herdr agent prompt <lead> "<comment URL> critique"` or `"... agree"`; add both to Messages and to the Turns list with the QUESTION/ANSWER additions in 2.
26. Confirm, P2. `README.md:119` and `:233` say the BLOCKED post notifies the dispatcher itself; `common.md:53` says post then prompt, with no exception. Fix: at `common.md:53` add "except BLOCKED: its post already notifies the dispatcher; do not prompt again."

**Open for Codex:** 18 (default exclusion vs per-call flag) and whether my retentions on 2, 4, 10 and 13 change any verdict. Everything else I consider agreed.

## Round 2 — Codex

Rechecked the cited instructions and harness at `5502863`. This round changes only this section.

18. **Agree.** Accept default exclusion when the first feature suite is added, with the documentation changes Fable accepts. `test/test_helper.exs:1` currently says `ExUnit.start()`; `roles/implementer.md:56-60` requires a separate browser run and then says “Plain `mix test` covers the rest”. Default exclusion makes that separation apply to ordinary test calls without a repeated flag. My objection was an undocumented loss of coverage: `README.md:38` currently names only `mix test`. Replacing that check instruction with both required runs, recording both results and excluded counts, and changing the browser command to `mix test --only browser --trace` addresses it. Retain the existing serial/timeouts-off requirement. No browser duplication is claimed at this head.

2. **Disagree with the retained categorical allow-list claim; agree with explicitly listing both messages.** `README.md:204` admits “the design-phase messages the designer role lists” and links the whole role, not its Messages heading. That role explicitly says “Post an ANSWER linking the QUESTION, evidence and decision, then notify the implementer” at `roles/designer.md:26-27`. Its Messages list also contains “Notify critics after each PROPOSAL” at lines 88-89, so “lists no notify message” is too broad. The omission of QUESTION/ANSWER notifications from that summary is real; it does not prove the role-wide reference authorizes no ANSWER notification. Describe this as incomplete and inconsistent enumeration, with no explicit UX QUESTION route. The agreed fix remains: list the question and answer notices explicitly, route the answer to its requester, and allow unaffected work to continue after a question notice. `board.py:108-109` still automatically notifies only for BLOCKED.

4. **Agree.** Name a board record the dispatcher can inspect: the receiving lead's reply accepting the linked handoff, identifying the responsibility it accepts. `roles/designer.md:82` requires “an accepted handoff to a reachable lead on an affected team”; `roles/common.md:20` says “Silence, a timeout or a missing agent never counts as consent or approval.” `roles/dispatcher.md:118-119` currently delegates this rule to the designer file, while `dispatcher.py:34` loads only common.md and dispatcher.md. Put the observable acceptance requirement in the dispatcher's own instructions. This makes the existing requirement checkable; it does not ask the dispatcher to judge technical completeness. Finding 15 uses the same check before retirement.

10. **Agree.** Delete “in their own words” from the approval instruction and give the filled-in line. `roles/ux-designer.md:60-61` currently puts that phrase immediately before the approval template, while `github.py:24` requires `^APPROVED candidate [0-9a-f]{40}\b`. The phrase could describe the scope and exceptions, so I still would not call the two requirements logically incompatible. Removing the ambiguity is nevertheless a useful operational fix. Keep the user's authorship, full-SHA validation against the proposed candidate, and correction path before the dispatcher retires the team (`roles/dispatcher.md:100-102`).

13. **Agree.** Replace the tester's duplicated comparison/severity/fetch instructions with the link to the review skill's authoritative procedure. `roles/tester.md:48` says “severity by consequence”; `review-software-design/SKILL.md:117-118` gives the concrete mapping, including “P1 when an approved constraint fails or is unproven”. The statements can agree, but separate copies invite drift and require extra reading. Consolidation resolves that cost without claiming the severity statements currently contradict one another. Keep the agreed pinned-fetch procedure and explicit override of the vendored instructions.

Other retentions checked:

- **5: Agree.** Remove the unconditional “the software designer judges feasibility” (`roles/ux-designer.md:4-5`) and use the QUESTION route when feasibility needs a technical decision. This preserves conditional consultation. `team.py:819-829` lets a software designer join an existing nonempty UX design record; the prompt-routing repair remains necessary.
- **6: Agree with the narrowed loading claim, not measured savings.** `config.py:553-554` places the clone at `allocations/<id>/project`. Anthropic documents subdirectory CLAUDE.md loading “on demand when Claude reads files in that directory”. That supports loading on a Claude worker's qualifying clone read, even though it was not loaded at launch. [Claude Help Center](https://support.claude.com/en/articles/14553240-give-claude-context-claude-md-and-better-prompts). `dispatcher.py:35-36` explicitly excludes CLAUDE.md for the restricted dispatcher. No session-level saving was measured; relocation remains the user's policy choice.
- **15: Agree.** `roles/designer.md:81-84` requires completing the assignment and handoffs or recording an accepted handoff; it also says not to retain the slot until dependent features merge. Use finding 4's board evidence alongside `done`, not `done` alone.
- **17: Agree with the fix; still dispute “a cost every review pays”.** `roles/implementer.md:49-55` mandates bounded log reads for that role. Its absence from the tester role permits excess output; it does not prove every tester reads excess output, or establish the size of that cost. Keep the shared log-reading rule and retain the 300-line/navigation mechanics as agreed. State the consequence as avoidable context use, without claiming a measured or universal occurrence.
- **22: Agree that the user chooses between the two completion policies.** `SETUP.md:12` already defines a Status field; option (b) adds a status **value**, not another field. This correction does not change the decision or the need to update the dispatcher and Item closed automation if PRODUCT.md's definition stays. Recommendation (a) is not authorization to change the product rule.
- **24: Agree.** Preserve `write_helpers`: `bootstrap.py:268` performs `link.symlink_to(shared)`, and line 293 calls that helper from `prepare`. Skip dependency fetching and Dexter execution for graphic designers, pass the role explicitly in bootstrap settings, and update the launch description. `team.py:349` currently records `kind`, not role.

25. **Agree, P1.** `roles/designer.md:59-64` instructs critics to post CRITIQUE/AGREE without notifying the lead; line 90 lists only the comment types. `board.py:108-109` notifies only for BLOCKED, and `roles/common.md:13` says “Do not poll.” Use the proposed `critique` and `agree` prompts. Apply the CRITIQUE notification to the initial critique in step 1 as well as later critiques in step 2, and list both messages in Messages and Turns. Every awaited critique must wake the lead.

26. **Agree, P2.** `roles/common.md:53` says “Post the comment, then send the Herdr prompt as a separate step”; `README.md:233` says “A BLOCKED post always notifies the dispatcher”. `board.py:121` performs that prompt. The proposed BLOCKED exception removes duplicate delivery. Keep the command's own failure/reporting path at `board.py:123-128`.

All remedies are agreed, with the clarifications above. Consensus is not yet reached on all 26 findings' evidence claims: I still dispute finding 2's categorical claim that the allow-list permits no ANSWER notification, and finding 17's claim that excess log-reading cost occurs in every review. Neither dispute requires a different remedy.

Verification: all pre-existing content is byte-for-byte unchanged. `python3 scripts/check_docs.py` still exits 1, now because the literal link-opening syntax in Fable's introductory explanation is itself parsed as a link. The exact error is “AssertionError: docs/brainstorm/agent-instructions-review-chavruta.md: broken local link ` by regex, so code spans do not exempt them”. An in-memory control excluding Round 2 produces the same error. That text is outside my permitted section and remains unchanged.

## Round 2 — Fable

Both remaining disputes are conceded; they change wording, not remedies.

2. Conceded. `designer.md:88-89` does list "Notify critics after each PROPOSAL", so "lists no notify message" was wrong. Agreed wording: the designer's Messages list and the Turns list enumerate the design-phase notices incompletely; neither names a QUESTION or ANSWER notice, and no UX QUESTION route exists. Remedy unchanged.
17. Conceded. Agreed wording: the tester's missing log rule permits avoidable context use; no size or frequency is claimed. Remedy unchanged.

Also fixed: my Round 1 intro contained the literal link-opening syntax; `python3 scripts/check_docs.py` now passes on this file.

Consensus: all 26 findings agreed on defect, severity and remedy, with the clarifications in Codex's Round 2 (ANSWER to the requester; question notices do not end the turn; critique notice also for the critic's step 1; observable acceptance record for handoffs; `status` prints entry, role, kind, model and capacity; default browser exclusion with both runs recorded; graphic designers keep `write_helpers`). Finding 22 and the CLAUDE.md relocation (6) and the story-issue rule (7, PRODUCT.md line) are the user's decisions.

## Round 3 — Codex

Confirmed: consensus is reached on all 26 findings, with the agreed amendments and clarifications; the policy choices identified in Fable's Round 2 remain the user's decisions.
