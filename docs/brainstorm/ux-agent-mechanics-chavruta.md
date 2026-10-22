# UX/UI design team: mechanics. Adversarial chavruta (Fable x Codex), 2026-10-22

Shared record. Each side appends under its own heading. Do not edit the other side's text.
Read-only: no file edits outside this record, no GitHub posts, no team.py, bootstrap, herdr or mix runs.
Plain English. Short lines. The user has ADHD. No praise, no filler.

Binding: the 18 principles in docs/brainstorm/ux-agent-principles-chavruta.md (Round 8 consolidated; P6, P17, P18 as amended in Round 9). Mechanics must satisfy them; a mechanic that needs a principle changed says so.

Metric and constraint as in the principles record: greenfield MVP, move fast, simplest well-engineered working workflow, reuse over invent.

## The user's requirement (2026-10-22, fixed)

- The design team has at least one UX/UI designer agent and one or more graphic designer agents.
- Both roles' models are configurable per entry in config.toml.
- Default UX designer: Opus 5.5. Graphic designers chosen so far: Codex (gpt-6-astra, medium) and Gemini 4 Argon (medium) through the `agy` CLI.

## Facts (main checkout at 80c74f6)

- `ROLES = ("designer", "implementer", "tester")` config.py:138; `TABS` :140; kinds `claude|codex` :344. `design()` accepts only role `designer` team.py:777 and adds the allocation with duty `designer` :790. A new standalone design team reads `Lead:` through `spec_lead` github.py:101, which also requires role `designer`.
- `client_args` team.py:497: Codex gets `-a <approval> -C <root> -m <model> -c model_reasoning_effort=<effort>`; everything else gets Claude flags. `launch()` sends "Begin." to Claude and the brief as the first message to others (:680). `running_client` refuses a live client that reports no session (:545).
- Every allocation gets a clone, `mix deps.get`, Dexter, a database suffix and a port (`allocate`, `configure_bootstrap`). Design allocations bootstrap detached at origin/main (bootstrap.py:179). A pair's implementer starts `task/<brief>` from its origin branch when one exists (:174).
- `stop` retires a standalone design team without a merged PR (README.md:145); cleanup deletes a clone that is clean and fully pushed, including ignored `tmp/` (:162). `/tmp/` is git-ignored at the repo root (.gitignore).
- The dispatcher's `start_design(spec, entry)` calls `team.design` once per entry (adapter.py:192). It has `retire_team`, `start_pair`, `prompt_agent`, `board_post`.
- `herdr agent prompt <name> "<text>"` is how clients message each other (README.md:122-123). `agy` is on PATH; `agy models` lists `gemini-4-argon-medium`; flags include `--model`, `--effort`, `--mode auto`, `-i <prompt>`. Herdr lists `agy` as a kind. Whether Herdr reports an agy session id is unverified.
- Codex `imagegen` saves under `$CODEX_HOME/generated_images/` and its skill says to copy project-bound images into the workspace and report final paths and prompts (imagegen/SKILL.md:33-40, :113). Agy saved the user's trial image under `~/.gemini/antigravity-cli/brain/`.
- Tests: agent/teams/tests, about 5,000 lines; `test_team.py` and `test_github.py` cover launch and roster parsing.

## Round 1: Fable

### M1. Config

Two new roles, one new kind. Config entries, models per entry:

```toml
[agents.opus-ux]
role = "ux-designer"
kind = "claude"
model = "claude-opus-5-5"
effort = "high"
db_suffix = "_ux"
port_offset = 5

[agents.astra-graphic]
role = "graphic-designer"
kind = "codex"
model = "gpt-6-astra"
effort = "medium"
db_suffix = "_astrag"
port_offset = 6

[agents.argon-graphic]
role = "graphic-designer"
kind = "agy"
model = "gemini-4-argon-medium"
effort = "medium"
db_suffix = "_argon"
port_offset = 7
```

Code: `ROLES` and `TABS` (both new roles in the `designers` tab), kind `agy` accepted. About 5 lines.

### M2. Roster lines on the brief

```
UX: opus-ux
Graphic designers: astra-graphic, argon-graphic
```

`roster()` gains these two optional lines. If `UX:` is present, `Graphic designers:` must name at least one configured graphic-designer entry; roles are checked. No `UX:` line means an ordinary brief. About 25 lines in github.py plus tests.

### M3. Launch

The dispatcher launches the design team on the brief with the existing tool, once per entry: `start_design(brief, opus-ux)` then `start_design(brief, astra-graphic)` and `start_design(brief, argon-graphic)`. `design()` is adapted: when the issue is a brief with a `UX:` line and no record, it creates the standalone design team with lead = the `UX:` entry and labels `phase:design`, `turn:opus-ux`; graphic designers join it. About 15 lines in team.py. No new command, no new adapter tool.

### M4. Allocations

Uniform: every client, including graphic designers, gets the standard allocation and runs `bootstrap.py`. Cost: a clone, `deps.get` and a Dexter start per graphic designer, unused. Reason: zero code. Revisit under P16 if the minutes hurt.

### M5. Client kind `agy`

`client_args` for `agy`: `--mode auto --model <model> --effort <effort>`; launch sends the brief as the first message like Codex. Unverified: Herdr's agy session id, approval behaviour in auto mode, whether agy runs `herdr agent prompt`. Plan: a Codex-only probe first (P10 allows it), then the agy adaptation with the facts the probe gives. About 10 lines plus tests, plus whatever the probe reveals.

### M6. Intake with the user

The UX designer talks to the user in its own Herdr pane; the user types there. It asks for ideas, then grills (P17). The user may drop a sketch path in the pane or on the issue. When the user confirms, the UX designer posts the grilled understanding as a PROPOSAL on the brief. That comment is the generators' brief (P18). No new channel.

### M7. UX designer to graphic designers

The UX designer writes `tmp/ux/brief-<n>.md` in its own clone and prompts each graphic designer: `herdr agent prompt team-<slot>-<entry> "Generate: <absolute path to brief-<n>.md>"`. A graphic designer reads that file, generates, copies the selected images into its own clone at `tmp/graphics/<n>/` with `prompts.md` (actual prompts, generator, limitations), and replies `herdr agent prompt team-<slot>-opus-ux "<absolute path> done"`. Reads across allocations are allowed; writes stay in the writer's allocation. The UX designer copies what it keeps. No shared folder, no new command.

### M8. Candidate and approval

The UX designer runs `git checkout -b task/<brief> origin/main` in its clone (design allocations are detached; nothing in the harness forbids a branch), commits `design/<brief>/` with `candidate.md` (scope, component map, states, copy, behaviours the images cannot show, provenance), the selected PNGs, and `prompts/`. Pushes. Posts a PROPOSAL on the brief: the SHA, each image embedded by its GitHub blob URL with `?raw=true`, and the open choices. The user replies on the brief: `APPROVED candidate <SHA> for <scope> with <exceptions or none>`. Rejections go back to the pane; a new candidate is a new commit and PROPOSAL.

### M9. Handoff to the pair

The dispatcher's release gate gains one condition for a brief with `UX:`: an APPROVED comment by the user whose SHA is the tip of origin `task/<brief>`. Then `retire_team(brief)` (standalone design team, allowed) and `start_pair(brief)`. The implementer's clone starts `task/<brief>` from origin (bootstrap.py:174) and holds the candidate. The implementer's launch brief names `design/<brief>/candidate.md` at the SHA. Zero lifecycle code; two dispatcher calls.

### M10. Tester

tester.md gains one step: at the viewports `candidate.md` names, screenshot the built page with `agent-browser` and compare side by side with the approved PNGs; report by consequence (P8). Nothing else changes.

### M11. Files

- `agent/teams/roles/ux-designer.md`: authority, read list, intake (ask for ideas, grill), direction of graphic designers, curation, candidate and approval, handoff, messages, do-nots. Triggers to tools (Intent, Impeccable) as a table.
- `agent/teams/roles/graphic-designer.md`: read the brief file named in the prompt, generate with the client's own image skill, inspect, copy into own `tmp/graphics/<n>/`, write `prompts.md`, reply with the path. Never post on GitHub. Never talk to the user.
- dispatcher.md: the UX phase (launch three, wait for APPROVED, retire, start pair). designer.md unchanged.
- SETUP.md: Intent and Impeccable into `.agents/skills`; `agy` installed and signed in; `grilling` at `~/.claude/skills`.
- `design/<brief>/` tracked; README "Where files belong" gets a row.

### Honest size

Harness code about 60 lines plus about 150 lines of tests; three role-file edits and two new role files; config and docs. One unverified client kind.

### Where I expect you to push

1. M3: three `start_design` calls versus one new `team.py ux <brief>` command. Count what the dispatcher must get right three times.
2. M4: uniform bootstrap for a client that never opens the project. Is a `--no-project` bootstrap smaller than the minutes it saves per story?
3. M7: file-path handoff through `herdr agent prompt` and cross-allocation reads. Name the failure modes: path typos, a graphic designer that never replies, two generators finishing at once.
4. M8: tracked `design/<brief>/` with PNGs. Repo growth, and whether the implementer should delete it after merge.
5. M5: the agy session id risk at team.py:545. If Herdr reports none, what is the smallest fix: skip the check for that kind, or probe Herdr first?
6. M6: intake in the pane. The user must notice the pane is waiting. Is a Herdr notification, a QUESTION comment, or nothing the right signal?

### Questions for Codex

Q1. For M1 to M11: accept, amend with the exact change, or reject with the cost. One line each.
Q2. The six pushes, one short paragraph each, with path:line where you have it.
Q3. Any mechanic that violates a principle? Name both.
Q4. Your honest size estimate if you disagree with mine.
Close with "consensus" or the remaining list.

## Round 1: Codex

Product question: can the design team hand an approved candidate to a working pair?
Disproof signal: extra coordination, lost artifacts or unresolved UX choices at handoff.

Read both records fully. Binding P17 means Round 9 Codex's replacement,
accepted in Round 10, not the earlier Round 9 Fable wording.
Source inspected at `80c74f6467d93ddc27f8143dab143445ded27701`.
Applied design-software; read the Herdr skill for help and messaging semantics.
`agy --help` exited 0; `herdr agent` printed its command group and exited 2.
The latter lists `agy`; the former lists the proposed model, effort and mode flags.
Neither verifies a model identifier, permissions, session identity or a successful launch.
No clients, bootstrap, Mix, tests or generation were run.

### Q1. M1 to M11

- M1 — Accept the configurable roles, kinds and shared designers tab; the shared label already selects one tab (`agent/teams/team.py:392`).
- M2 — Amend: parse the UX assignment separately without changing the pair roster's return shape; reject orphaned, duplicate or wrong-role entries, and reject both new roles in Required reviews until deliberately supported (`agent/teams/github.py:113`, `:135`).
- M3 — Amend: launch UX first; after its confirmed intake is recorded, launch the assigned graphic entries as needed; preserve their actual duties and generate role-specific launch prompts (`agent/teams/briefs.py:101`; principles record `:735`).
- M4 — Accept uniform allocations for the first trial; count their full preparation time and failures, and do not claim the graphic designers need no project reads (`agent/teams/bootstrap.py:290`).
- M5 — Amend: add an explicit agy argument branch and verify agy identity, prompting and permissions directly; do not make a Codex-only probe the prerequisite or skip identity checks (`agent/teams/team.py:505`, `:554`).
- M6 — Amend: use the accepted bounded P17, record the confirmed understanding and authorized exploration, and notify the dispatcher when intake needs the user or is ready for graphic launches (principles record `:753`; `agent/teams/roles/dispatcher.md:15`).
- M7 — Amend: use immutable per-request files linked to the intake comment; include request, recipient and input revision in both message and reply; route failures to UX; freeze selected outputs before retirement (`agent/teams/README.md:162`).
- M8 — Amend: configure UX's bootstrap branch as task/<brief> from the outset; reuse a legitimate existing branch without overwriting another owner; preserve native selected images, reference inputs, prompts, versions and disclosed differences; link every approval image at the candidate SHA (`agent/teams/bootstrap.py:183`; P3).
- M9 — Amend: retain retire then start, but add branch-tip verification to the existing start_pair/start path, carry the approval URL and full SHA into the handoff, and require the implementer to verify its actual starting HEAD (`agent/teams/roles/dispatcher.md:6`; `agent/teams/bootstrap.py:174`).
- M10 — Amend: compare against the approved SHA, not a candidate file changed at the PR head; include interactions, authoritative copy, system revision and disclosed differences in the combined review (principles record `:702`).
- M11 — Amend: include role-specific launch text, roster/reviewer validation and release verification in the file list; scope graphics' common-rule exceptions, use configured recipient names, and document skill access for each actual client (`agent/teams/briefs.py:14`, `:101`; `agent/teams/roles/common.md:43`).

### Q2. The six pushes

1. **Separate launches.** Keep start_design; do not add a ux command yet. For each graphic entry, the dispatcher must select the right issue and assigned entry, launch only after intake, and handle a partial failure without replaying completed work. Launch adoption already avoids resending the task (`agent/teams/team.py:607`). One bulk command would still need partial-success handling and could not launch UX and generators together under P18. Use the roster's one-or-more entries, not three hard-coded names. The graphic launch prompt must name the recorded assignment or wait for UX direction; the current prompt invokes software-design steps (`agent/teams/briefs.py:103`).

2. **Uniform bootstrap.** Accept its known cost for one trial; no evidence here establishes the minutes saved. A no-project mode would also need another way to supply role files, skills and relevant source. Current bootstrap fetches dependencies and starts Dexter (`agent/teams/bootstrap.py:290`), while its prompt requires repository instructions (`agent/teams/briefs.py:20`). If preparation proves costly, compare a clone-and-skills-only path with the full path before removing the clone. Measure the work actually performed: allocate reserves resources (`agent/teams/team.py:250`); that alone does not show a database was created. No new provisioning mode is justified solely by a guessed line count.

3. **File handoff failures.** A typo or unreadable input must return a named failure, not trigger guessing. Never overwrite a brief while a generator may read it. Distinct request/entry directories make concurrent replies independent; UX discards stale replies by request revision and copies only complete outputs. A missing reply is not proof of a failed send: Herdr's skill explicitly distinguishes submission from execution (`.agents/skills/herdr/SKILL.md:145`). Inspect state before any replay; use the existing stopped-agent route (`agent/teams/roles/dispatcher.md:119`). Cross-allocation reads must be permitted and verified in each client runtime. Make the temporary file link back to the durable intake decision, rather than becoming a competing spec.

4. **Tracked images.** Keep selected candidates in Git for this small first slice; curate in tmp before committing a candidate for approval. Preserve JPG as JPG when that is the selected output, rather than imposing PNG on the reported agy result. Record candidate bytes at freeze; do not create an archive service now. Removing files in the implementation PR can keep the current tree small, but cannot remove their size from reachable Git history. No post-merge cleanup commit is required. Keep the approved commit reachable through the merged branch history and its SHA links. Temporary-only media would disappear at retirement (`agent/teams/README.md:162`). Verify the issue's embedded images actually display before asking for approval; a constructed URL is not execution evidence.

5. **agy identity.** Probe agy under Herdr during implementation before choosing a fix; a Codex probe cannot answer this. The precise missing-session refusal is at `agent/teams/team.py:555`, not :545. Skipping it accepts an unproven replacement client and weakens recovery. Session extraction currently reads agent_session.value (`agent/teams/herdr.py:67`); determine whether agy supplies it, including after restart. If not, identify an equally reliable supported identity or report the integration blocked. Help confirms --mode auto exists, not its permission guarantees. Preserve existing denial handling; do not substitute permission bypass flags. The permitted help commands supplied no evidence for changing these checks.

6. **Waiting for the user.** Use the existing issue question and dispatcher route when the user is absent: post one actionable QUESTION, prompt the dispatcher with its link and the UX pane identity, then stop. The dispatcher is event-driven (`agent/teams/roles/dispatcher.md:15`); a comment alone does not establish that it was notified. If the user is already conversing in the UX pane, ask there without duplicating every frontier on GitHub. Record the confirmed decision before generation. Do not add a notification subsystem, repeated reminders or polling. Missing user input never becomes consent (`agent/teams/roles/common.md:20`).

### Q3. Principle violations and concrete gaps

- **M3/M11 versus P18:** launching all graphic designers immediately precedes the required intake record. The binding start condition is explicit in the principles record at :735. Stage the existing calls; no principle change is needed.
- **M7/M8 versus P3/P4:** the listed payload omits preserved reference inputs and rendered-source versions when used, and may duplicate settled copy or states. P3 requires provenance at principles :697; P4 at :698 requires links to authoritative facts. Include the missing inputs and link existing facts. A sketch path in another allocation is not durable provenance.
- **M8/M9 versus P3:** manual branch creation conflicts with the configured detached startup. On restart, bootstrap sees a different current branch, refuses unpublished work or returns a clean pushed checkout to origin/main (`agent/teams/bootstrap.py:183`). Configure the UX branch through the existing branch field; do not repair this with repeated checkout -b instructions.
- **M9 versus P3/P10:** the proposed dispatcher check is not available through its current tools. It has no shell and may not ask another agent to perform a missing tool operation (`agent/teams/roles/dispatcher.md:6`). The adapter exposes PR heads (`agent/teams/adapter.py:227`), not the pre-PR task branch. Add the narrow ref check to the existing start path. This is necessary adaptation, not a new lifecycle state.
- **M10 versus P8/P11:** screenshot comparison alone omits interaction evidence and the disclosed fidelity boundary. P8 explicitly includes both (principles :702). The existing tester scenario checks can supply that evidence; no second review is needed.

M9 also needs an explicit approval convention.
board_read currently emits comment text, URL and time, but drops author metadata
(`agent/teams/board.py:145`).
Agents share a GitHub identity (`agent/teams/README.md:255`), so author login alone
would not prove a human wrote a comment even if exposed.
Reserve the bare APPROVED record for the user; agent comments retain their headers.
Read the user's actual decision and its scope, not an agent's report of it.
Do not describe that convention as cryptographic authorship verification.
Hold on contradictory, superseded or unresolved conditional approval.

Freeze UX writes before retirement and carry the expected SHA into pair launch.
The implementer must check it before edits: a missing remote branch currently
falls back to origin/main (`agent/teams/bootstrap.py:177`).
A dispatcher check made earlier does not prove the clone's eventual starting revision.
The tester must retain the same approval reference after implementation advances HEAD.

M2's reviewer validation is a concrete omission from the estimate.
Adding roles to ROLES makes roster group those entries, but its return still includes
only tester and designer groups (`agent/teams/github.py:135`).
A graphic entry in Required reviews could silently disappear from required reviewers.
Reject unsupported reviewer roles explicitly; leave ordinary software-design review intact.

M11 must reconcile the new duties with common.md rather than load contradictory rules.
Graphic designers route findings and blockers to UX; UX records durable decisions.
This scopes common.md's direct-post requirement (`agent/teams/roles/common.md:43`).
Harness launch EVENTs remain allowed; they are not graphic-designer-authored posts.
Return to the configured UX entry, not the literal opus-ux in M7.
SETUP must give the Claude UX client readable Intent, Impeccable and grilling paths;
a directory intended for another client is not evidence of skill discovery.
The existing setup distinguishes client locations (`agent/teams/SETUP.md:31`).

### Q4. Size estimate

Sixty production lines is too low for the complete path described above.
My planning range is 180–350 changed Python lines and 250–450 test lines,
plus config, two new role files and updates to the existing roles and workflow docs.
These are estimates, not a patch count or a target.
They assume uniform bootstrap and a working agy session identity.
A Herdr compatibility change is outside that estimate and remains unverified.

The omitted work is role-specific prompts, explicit reviewer rejection,
UX branch/restart handling, and a branch verification path the dispatcher can invoke.
Use existing test fixtures for those contracts, including partial launches and retries.
Current lifecycle tests already cover role prompts and retirement
(`agent/teams/tests/test_team.py:1391`), and conflicting identities (`:1945`).
Extend those cases; do not create a separate UX lifecycle test framework.

Do not add agy token parsing just for parity in this first slice.
The usage code currently reads Claude or Codex logs (`agent/teams/board.py:289`).
Report agy usage as unknown until supported, not as a zero-cost agent.
A real agy smoke check remains required evidence; mocked launch tests cannot supply it.

Remaining: staged graphic launch, correct role prompts, validated roster boundaries,
agy identity and permission evidence, recoverable UX branch ownership,
a callable release check and receiver SHA check, complete candidate provenance,
and the interaction-aware tester step.

## Round 2: Fable

Verified: roster returns only tester and designer groups (github.py:135), so a graphic entry in Required reviews would vanish; bootstrap's finish_start refuses a clone on another branch with unpublished work (bootstrap.py:183), so a manual `checkout -b` breaks on restart; the missing-session refusal is at team.py:555; the dispatcher has no shell (dispatcher.md:6) and the adapter reads PR heads only (adapter.py:227); board_read drops author metadata (board.py:145); the harness header is the only mark that separates an agent comment from the user's. All hold.

### User decision, 2026-10-22 (new)

D6. The design team starts in its own Herdr tab, as the software designers do in `designers`. One tab, `ux`, for the UX designer and the graphic designers; the `designers` tab stays for software designers. This replaces M1's shared tab. Two roles in one tab: `open_pane` looks up the label by role (team.py:392) and splits off the tab's last pane, so two labels mapping to `ux` need no other change. If you see a reason for one tab per role instead, say it.

### Accepted, with facts

- M2. Separate parse; new roles rejected in Required reviews; orphaned, duplicate and wrong-role entries refused.
- M3. Staged launch: UX first; graphic designers after the intake record exists (P18). This is also cheaper: no graphic client idles through grilling. Role-specific launch prompts; the roster's one-or-more entries, no hard-coded names.
- M4. Uniform bootstrap for the first trial, with its cost measured.
- M5. An explicit agy argument branch, identity verified by a real agy launch under Herdr during implementation. A Codex-only trial may exercise the loop; it does not count as agy evidence. If Herdr reports no agy session, the integration is blocked and reported; the check at :555 is not skipped.
- M6. The user present in the pane: ask there. The user absent: one QUESTION on the brief, then prompt the dispatcher with its link and the pane name, then stop. No reminders, no polling.
- M7. Immutable per-request files under `tmp/ux/requests/<n>/brief.md`, linked to the intake comment; message and reply carry request number, recipient and input revision; a graphic designer's failure returns a named failure to UX; stale replies are discarded by request number; selected outputs frozen before retirement.
- M8. The UX designer's bootstrap is configured with branch `task/<brief>` through the existing branch field; `design()` passes it for a ux-designer entry. An existing origin branch is reused, never overwritten. Native formats kept (JPG stays JPG). Candidate payload: selected images, reference inputs (the user's sketch copied in), actual prompts, generator and version, rendered source and asset versions when used, disclosed differences, links to settled copy and states instead of copies.
- M9. The gate lives in `team.py start`, not in the dispatcher's instructions: for a brief with `UX:`, `start` reads the brief's comments, accepts `APPROVED candidate <SHA> ...` only from a comment without a harness header, requires that SHA to equal the tip of origin `task/<brief>` (via `gh api`), and refuses otherwise with the reason. The implementer's launch brief carries the SHA and the approval URL; the implementer checks `git rev-parse HEAD` against it before any edit, because bootstrap falls back to main when the branch is missing (:177). Not cryptographic; a shared-identity convention.
- M10. The tester compares against the files at the approved SHA, not the PR head, and keeps interactions, authoritative copy, system revision and disclosed differences inside its existing scenario checks.
- M11. Role-specific launch text, roster and reviewer validation, and the release check join the file list. Graphic designers route findings and blockers to the UX designer, who posts; this scopes common.md:43 for that role. Recipient names come from the configuration. SETUP: Intent and Impeccable into `.agents/skills`, which bootstrap links into every clone and the UX role names as the read path; `grilling` at `~/.claude/skills` is user scope and auto-discovered by Claude; `agy` installed and signed in.
- Q4. Your range (180 to 350 Python, 250 to 450 test lines) replaces mine. Not a target. agy usage reported as unknown until board.py supports it.

### Retained

- The retire-then-start lifecycle (M9) stays: two existing dispatcher calls, with the gate inside `start`. No new record kind, no kind transition.
- Tracked `design/<brief>/` stays for this slice; no post-merge deletion rule.

### Final mechanics, consolidated

M1. Config. Roles `ux-designer` and `graphic-designer`; kind `agy`; both roles in a new `ux` tab. Entries as in Round 1, models per entry.
M2. Brief lines `UX: <entry>` and `Graphic designers: <entry>, ...` (one or more); parsed separately from the pair roster; invalid or orphaned entries refused; new roles refused in Required reviews.
M3. Dispatcher: `start_design(brief, <ux entry>)`; after the intake PROPOSAL exists, `start_design(brief, <graphic entry>)` per entry. `design()` creates the standalone design team on a brief with `UX:`, lead = the UX entry, labels `phase:design`, `turn:<ux entry>`; configures the UX designer's branch `task/<brief>`; graphic designers join. Role-specific launch prompts.
M4. Uniform allocations and bootstrap for every client; cost measured on the first story.
M5. agy client arguments `--mode auto --model <model> --effort <effort>`; brief sent as first message; identity, prompting and permissions verified by a real agy launch during implementation; blocked and reported if Herdr gives no session.
M6. Intake in the UX pane when the user is there; otherwise one QUESTION on the brief and a prompt to the dispatcher naming the link and pane. Confirmed understanding and authorized exploration posted as a PROPOSAL before any generation.
M7. Per-request immutable brief files in the UX clone; `herdr agent prompt` with request number, recipient and revision; graphic designers write only under their own `tmp/graphics/<n>/` with `prompts.md`; reply names the path; failures named, stale replies discarded.
M8. Candidate at `design/<brief>/` on `task/<brief>`: `candidate.md` plus images, references, prompts; pushed; PROPOSAL with SHA and embedded images, display verified; the user posts `APPROVED candidate <SHA> for <scope> with <exceptions or none>`.
M9. `retire_team(brief)` then `start_pair(brief)`; `start` enforces the approval gate and branch tip; the implementer verifies its HEAD against the approved SHA before editing.
M10. Tester: side-by-side at the named viewports against the approved SHA's images, inside its existing combined review with interaction evidence.
M11. Files: `roles/ux-designer.md`, `roles/graphic-designer.md`, dispatcher.md UX phase, tester.md step, README roster and tab lines, SETUP skills and agy, config.toml entries, `design/` row in the README table; harness: config.py roles, tabs and kind; github.py UX parse and reviewer rejection; team.py design branch, start gate, agy args; briefs.py two prompts; tests extended in test_team.py and test_github.py.
M12. Trial: first UI story runs the loop; agy launched for real before the three-agent team is called ready; retro under P16.

### Questions for Codex, round 2

Q5. D6: one `ux` tab for both roles, or one tab per role? Cite pane logic if sharing breaks anything.
Q6. M1 to M12 consolidated: "accept" or the exact replacement line. One line each.
Q7. Anything remaining. Else "consensus".


## Round 2: Codex

### Q5. Tab

One `ux` tab for both roles.
The lookup uses the mapped label, then finds siblings by that tab's ID
(`agent/teams/team.py:392`, `agent/teams/team.py:410`).
Both roles mapping to `ux` therefore share the existing split logic.
No separate tab per role is needed.

### Q6. Consolidated mechanics

M1. accept
M2. accept
M3. accept
M4. accept
M5. accept
M6. accept
M7. Per-request immutable brief files in the UX clone; `herdr agent prompt` and replies carry request number, recipient and input revision; graphic designers publish handoff artifacts under their own `tmp/graphics/<n>/` with `prompts.md`, copying selected outputs there from the generator's native save location when necessary; replies name the path; failures named, stale replies discarded.
M8. accept
M9. `retire_team(brief)` then `start_pair(brief)`; on initial pair creation, `start` enforces the approval gate and remote branch tip, and pins the approved SHA and approval URL before allocating clients; the implementer's initial checkout must equal that SHA before implementation edits; retries and relaunches reuse the pinned approval and preserve implementation progress, checking that the approved commit remains an ancestor of HEAD instead of requiring HEAD or the advancing remote tip to equal it; the dispatcher retains the release decision for scope, supersession and unresolved conditions.
M10. accept
M11. accept
M12. accept

### Q7. Remaining

Two wording fixes above remain.

M7's absolute write restriction conflicts with built-in image generation.
The tool saves under CODEX_HOME and the skill requires copying selected project assets
into the workspace afterward
(`/Users/chenghanlee/.codex/skills/.system/imagegen/SKILL.md:34`,
`/Users/chenghanlee/.codex/skills/.system/imagegen/SKILL.md:36`).
Restrict the handoff destination; allow that native save step.
This does not authorize changes to tracked project files by graphic designers.

M9 must distinguish initial release from recovery.
`start_pair` explicitly supports relaunches (`agent/teams/adapter.py:178`).
`start` reuses allocations and calls the same launch-brief builder
(`agent/teams/team.py:751`, `agent/teams/team.py:770`).
That builder explicitly serves relaunched clients (`agent/teams/briefs.py:53`).

Approve candidate A, launch, commit and push implementation B, then relaunch.
The proposed unconditional gate rejects B because B is not A.
Without a push, the repeated HEAD check still rejects local implementation progress.
Expected: retain approval A as the comparison baseline and resume B.
Bootstrap already preserves the configured branch (`agent/teams/bootstrap.py:187`).
Persist the approval with the existing pair record, including partial-start recovery;
do not derive a new baseline from the implementation tip on retry.
Extend the existing lifecycle tests for initial release, partial launch and relaunch
with implementation commits and uncommitted work preserved.

Keep the earlier hold on superseded or unresolved conditional approval
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:190`).
A bare APPROVED comment matching a SHA is necessary but does not resolve scope
or a later user hold. The dispatcher already checks unresolved decisions before release
(`agent/teams/roles/dispatcher.md:71`, `agent/teams/roles/dispatcher.md:77`).
Keep that judgment there; the machine gate need not interpret arbitrary prose.

## Round 3: Fable (cut pass)

User reminder, 2026-10-22: simplest well-engineered solution; design-team and agent-team complexity sit in the metric's denominator. So this round cuts. Rule: a guard against a failure that is cheap, visible and self-correcting is cut; the role file says what the agent checks instead.

Verified: `start` reuses allocations and the same brief builder on relaunch (team.py:751, :770; briefs.py:53); bootstrap preserves a configured branch on reuse (bootstrap.py:187); imagegen saves under CODEX_HOME first (imagegen/SKILL.md:34, :36). Your relaunch case is right: a gate requiring HEAD to equal the approved SHA rejects the implementer's own progress.

### Cuts

- M9 gate in `start`: cut entirely. No comment parsing, no header detection, no `gh api` ref read, no pinned approval in the record. Replacement, zero harness code: the implementer's role file says, before the first edit, read the brief's APPROVED comment and run `git merge-base --is-ancestor <SHA> HEAD`; if there is no APPROVED comment or the check fails, post BLOCKED. The ancestor check is the same on first launch and on relaunch. The dispatcher keeps the release judgment it already has (dispatcher.md:71, :77): it reads the brief, sees the user's APPROVED comment, retires, starts. A pair started too early fails at the implementer's first step and reports blocked. Cheap, visible, self-correcting.
- M6 absent-user path: cut. The user is on this machine and started the dispatcher. Intake waits in the UX pane. The dispatcher's report to the user after launch names the pane. No QUESTION comment, no dispatcher prompt, no reminders.
- M7 revisions and stale-reply rules: cut. Keep numbered request directories so nothing is overwritten; the reply names the path or a named failure. The UX designer can tell replies apart by path.
- M11 release-verification file item: gone with the gate.

### Accepted

- M7 write rule as you wrote it: the generator's native save location is allowed; the handoff destination is the graphic designer's own `tmp/graphics/<n>/`; tracked project files are never touched by graphic designers.
- Q5: one `ux` tab.
- M2 reviewer guard stays: two lines that refuse a non-reviewer role in Required reviews, because the alternative is a silently missing reviewer, which is neither visible nor self-correcting.

### Final mechanics after the cut

M1. Config: roles `ux-designer`, `graphic-designer`; kind `agy`; both roles in one `ux` tab; entries with model and effort per entry.
M2. Brief lines `UX: <entry>`, `Graphic designers: <entry>, ...` (one or more), parsed separately; invalid entries refused; non-reviewer roles refused in Required reviews.
M3. Dispatcher: `start_design(brief, <ux entry>)`; after the intake PROPOSAL, `start_design(brief, <graphic entry>)` per entry. `design()` on a brief with `UX:` creates the standalone design team, lead = UX entry, labels `phase:design`, `turn:<ux entry>`, UX branch `task/<brief>`; graphic designers join. Role-specific launch prompts.
M4. Uniform allocations and bootstrap for every client.
M5. agy arguments `--mode auto --model <model> --effort <effort>`; brief as first message; verified by a real agy launch during implementation; blocked and reported if Herdr gives no session.
M6. Intake in the UX pane. The confirmed understanding and authorized exploration are posted as a PROPOSAL before any generation.
M7. Numbered request files in the UX clone; `herdr agent prompt` carries the path; graphic designers hand off under their own `tmp/graphics/<n>/` with `prompts.md`, copying from the native save location; replies name the path or a named failure.
M8. Candidate at `design/<brief>/` on `task/<brief>`: `candidate.md`, selected images in native format, reference inputs, prompts, generator and version, disclosed differences, links to settled facts; pushed; PROPOSAL with SHA and embedded images; the user posts `APPROVED candidate <SHA> for <scope> with <exceptions or none>`.
M9. Dispatcher reads the APPROVED comment, `retire_team(brief)`, `start_pair(brief)`. The implementer checks the approved SHA is an ancestor of HEAD before its first edit, else BLOCKED.
M10. Tester: side-by-side at the named viewports against the approved SHA's images, inside its existing combined review with interaction evidence.
M11. Files: `roles/ux-designer.md`, `roles/graphic-designer.md`; dispatcher.md UX phase; implementer.md ancestor check; tester.md step; README roster and tab lines; SETUP skills and agy; config.toml; `design/` row in the README table. Harness: config.py roles, tab, kind; github.py UX parse and reviewer guard; team.py design branch and lead, agy args; briefs.py two prompts; tests extended in test_team.py and test_github.py.
M12. First UI story runs the loop; agy launched for real before the team is called ready; retro under P16.

Honest size after the cut: about 80 to 150 Python lines, 120 to 250 test lines. Not a target.

### Questions for Codex, round 3

Q8. Each cut: accept, or name the failure it lets through that is not cheap, visible and self-correcting.
Q9. One more cut you would make that I did not.
Q10. "consensus" or what remains.


## Round 3: Codex

### Q8. Each cut

- M9 harness gate: accept. The issue remains the durable approval source.
  Read the user's current applicable approval, including scope and exceptions,
  on each launch or relaunch before editing. Missing approval, unresolved conditions
  or a failed ancestor check means BLOCKED. No extra record field or comment parser.
  The dispatcher retains release judgment (`agent/teams/roles/dispatcher.md:71`).
  An ancestor check proves history membership, not approval of later changes;
  implement and review against the files at the approved SHA, as M10 requires.
- M6 absent-user path: accept. Name the UX pane in the launch report and wait there.
  Absence does not authorize generation; M6's confirmed intake still applies.
- M7 revision fields and stale-reply protocol: accept. A unique, never-overwritten
  request path identifies the input without a second revision identifier.
  Use the same request number in its output directory and return a full path,
  so different clones cannot make two `tmp/graphics/1/` replies ambiguous.
  UX curates the result against the current question; no additional message schema.
- M11 release-verification item: accept. It disappears with the harness gate.

### Q9. One more cut

Cut duplicated workflow instructions from the two new launch prompts.
Use one shared launch envelope for identity, bootstrap, issue and configured role path.
Keep intake, generation, approval and message duties in the two role files.
Pass the configured UX recipient where needed; do not repeat its workflow in Python.

The existing `design_brief` already assembles a shared envelope
(`agent/teams/briefs.py:101`). Its software-designer assignment and direct-post text
are role-specific (`agent/teams/briefs.py:103`, `agent/teams/briefs.py:117`).
Keep that existing software path; let the new roles follow their own files.
This still needs role-aware launch text, but not two additional workflow descriptions.
It reduces instruction maintenance as well as code, the metric in P13
(`docs/brainstorm/ux-agent-principles-chavruta.md:707`).

### Q10. What remains

Restore one requirement in M8: retain rendered source and asset versions when used.
P3 requires it (`docs/brainstorm/ux-agent-principles-chavruta.md:697`);
the cut-pass M8 lists generated-image provenance but omits this case
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:376`).
A local render can settle a consequential interaction or fidelity choice.
Keeping only its screenshot loses the source that made the approved artifact.

Use this replacement fragment in M8:
"actual prompts, known generator details, rendered source and asset versions when used".
Unknown generator details stay unknown; do not require an invented version.

The four explicit cuts are accepted. Remaining: the M8 provenance restoration
and the Q9 proposal to keep workflow duties in their role files.

## Round 4: Fable

### Accepted

- M8 provenance: "actual prompts, known generator details, rendered source and asset versions when used". P3 requires it; unknown details stay unknown.
- Q9: one shared launch envelope in briefs.py for the two new roles (identity, bootstrap, issue, configured role path, configured UX recipient for a graphic designer). Duties live in the role files. The software designer's `design_brief` is untouched.
- M7 as you refined it: the request number names both the request file and the output directory; replies carry the full path.
- M9 as you refined it: read the user's current applicable approval, scope and exceptions on every launch; missing, unresolved or failed ancestor check means BLOCKED; implement and review against the files at the approved SHA.

### M13. Intent and Impeccable in the mechanics (P6)

The user asked where the skills sit. They are rows in the UX role file's trigger table, never a sequence. Grilling replaces Impeccable `shape`'s interview.

| Role | Step | Trigger | Tool |
|---|---|---|---|
| UX | intake | always | `grilling` (P17) |
| UX | intake | a multi-step flow still unclear after grilling | `/intent:journey` |
| UX | before briefing generators | wording unresolved | `/intent:articulate`; GOV.UK error text reused, not regenerated |
| UX | before briefing generators | recovery or non-default states unresolved | `/intent:fortify`; only the states that change a decision |
| UX | curation | a named risk in the returned images | one of `/intent:evaluate` or `/impeccable critique` |
| UX | curation | keyboard, focus or assistive question an image cannot settle | `/intent:include` spot-check |
| UX | design-system story only | real source exists | `/impeccable document` writes DESIGN.md |
| Implementer | before the PR | a page added or changed | `/impeccable audit` on the changed pages |
| Tester | review | a page added or changed | vendored Vercel web-design-guidelines on the templates, inside the existing review |
| Graphic designers | none | | their own image skill only |

Cut from the harness flow: `shape`, `live`, `generate`, `init`, `strategize`, `specify`, `present`: interactive, or duplicated by grilling, the brief and `candidate.md`.

Record: the candidate PROPOSAL carries one note, "Checked / Reused or not needed / Unverified". A command is named only when it supplied evidence worth keeping (prior consensus, ux-agent-chavruta.md Round 4 Codex Q16).

Install: Intent (`npx skills add ghaida/intent --all`) and Impeccable into `.agents/skills` in the main checkout, which bootstrap links into every clone; the UX role names that path. Neither is installed yet; SETUP.md lists both. The implementer's `audit` and the tester's guidelines come from the same place.

### Questions for Codex, round 4

Q11. M13: accept, or amend rows with evidence from the upstream skill docs you inspected yesterday. Push on `audit` for the implementer and the guidelines for the tester: both were yesterday's consensus; do they survive today's P6 and P13?
Q12. Final consolidated M1 to M13: "consensus" or what remains.


## Round 4: Codex

### Q11. M13

Amend. Mandatory audit was not yesterday's final consensus.
The closed record explicitly removed the implementer bullet
(`docs/brainstorm/ux-skills-chavruta.md:520`).
It retained guideline review inside the existing review
(`docs/brainstorm/ux-skills-chavruta.md:528`).

Replace the implementer row with:

| Role | Step | Trigger | Tool |
|---|---|---|---|
| Implementer | existing verification | the brief names a detector trial or a specific unresolved risk | use the sufficient check and record its evidence; no mandatory Impeccable audit |

[Audit](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/audit.md)
is a broad scored assessment with a report and follow-up recommendations.
It does not fix its findings. It includes a detector but is not the detector.
A page change alone does not justify that additional workflow under P6 and P13.
Keep the detector trial in its brief; one clean run does not make it mandatory
(`docs/brainstorm/ux-skills-chavruta.md:535`).

Replace the tester row with:

| Role | Step | Trigger | Tool |
|---|---|---|---|
| Tester | existing combined review | changed pages, forms or components | apply web-design-guidelines to affected templates, CSS and JS; record the fetched rules revision; assess findings against the brief and repository severity, within the combined P2 limit |

This survives P6 and P13: it supplies criteria to an existing review.
It creates no extra reviewer, report or command chain.
[The rules](https://github.com/vercel-labs/web-interface-guidelines/blob/434b7f91364665f2f733b310ec54809bf8f37937/command.md)
cover focus styling, motion and event behavior as well as markup.
Templates alone omit relevant CSS and JS.
Apply framework-specific examples to our actual code; upstream preferences do not
supersede approved behavior or establish accessibility through source inspection alone.
M10's rendered and interaction checks remain.

Replace the curation assessment row with:

| Role | Step | Trigger | Tool |
|---|---|---|---|
| UX | curation | a named unresolved risk in returned images | scoped Intent evaluate; choose Impeccable critique only when its additional assessment has a specific benefit and a suitable target |

[Evaluate](https://github.com/ghaida/intent/blob/3fc38dff381ce0e4dec8f52c97c3e37abd95e10e/skills/evaluate/SKILL.md)
explicitly scales its report to scope.
[Critique](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/critique.md)
requires separate design and detector assessments, isolated subagents when available,
a persisted snapshot and a closing question step.
These are not interchangeable costs for one image question.
This retains optional critique without making its machinery the default curation pass.

Replace the document row with:

| Role | Step | Trigger | Tool |
|---|---|---|---|
| UX | design-system story | approved source exists and guidance is missing or materially stale; artifact ownership is agreed | optionally use Impeccable document; otherwise maintain sufficient guidance in its existing home |

[Document](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/document.md)
writes DESIGN.md and, in scan mode, a design.json sidecar with component material.
Real source alone does not justify both artifacts.
Their authority was explicitly left for the design-system story
(`docs/brainstorm/ux-skills-chavruta.md:540`).
P15 still places the system in repository code and usage guidance
(`docs/brainstorm/ux-agent-principles-chavruta.md:709`).

Accept grilling, journey, articulate and fortify with the stated triggers.
Accept include as a scoped check of the relevant interaction demonstration or render;
without that surface, record design guidance and the unverified behavior.
Its [testing guidance](https://github.com/ghaida/intent/blob/3fc38dff381ce0e4dec8f52c97c3e37abd95e10e/skills/include/SKILL.md)
distinguishes keyboard and screen-reader testing from inspection.
Accept the graphic-designer row, the command cuts and the short judgment note.

Correct the install wording too.
The [Intent README](https://github.com/ghaida/intent/blob/3fc38dff381ce0e4dec8f52c97c3e37abd95e10e/README.md)
distinguishes skills installation from the Claude plugin that exposes `/intent:...`.
With the proposed skills-only installation, name the readable skill paths;
do not promise plugin commands or add a plugin solely to preserve table syntax.
The vendored guidelines use their repository path, not the Intent install directory.
The existing copy is at
`.worktrees/task-523/agent/skills/web-design-guidelines/SKILL.md:16`;
ensure the delivery includes that dependency or names its actual installed path.

### Q12. What remains

M1 to M12, with the accepted Round 4 amendments: consensus.
M13: remove mandatory audit, retain scoped guideline review, bound critique and document,
and align the named skills with the installation paths.

## Round 5: Fable (close)

Accepted on evidence: yesterday's close removed the mandatory implementer audit (ux-skills-chavruta.md:520) and kept guideline review inside the existing review (:528); `audit` is a scored report, not the detector; `critique` carries subagents, a snapshot and a closing step that one image question does not need; `document` writes two artifacts whose authority the design-system story decides; skills-only installs give readable paths, not `/intent:` plugin commands; the vendored guidelines live at their own repository path.

### M13, final

| Role | Step | Trigger | Tool |
|---|---|---|---|
| UX | intake | always | `grilling` (P17) |
| UX | intake | a multi-step flow still unclear after grilling | Intent `journey` |
| UX | before briefing generators | wording unresolved | Intent `articulate`; GOV.UK error text reused, not regenerated |
| UX | before briefing generators | recovery or non-default states unresolved | Intent `fortify`; only the states that change a decision |
| UX | curation | a named unresolved risk in returned images | scoped Intent `evaluate`; Impeccable `critique` only when its additional assessment has a specific benefit and a suitable target |
| UX | curation | keyboard, focus or assistive question an image cannot settle | scoped Intent `include` on the relevant demonstration or render; without one, record the guidance and the unverified behaviour |
| UX | design-system story | approved source exists, guidance missing or materially stale, artifact ownership agreed | optionally Impeccable `document`; otherwise maintain guidance in its existing home |
| Implementer | existing verification | the brief names a detector trial or a specific unresolved risk | the sufficient check, evidence recorded; no mandatory audit |
| Tester | existing combined review | changed pages, forms or components | web-design-guidelines on affected templates, CSS and JS; fetched rules revision recorded; findings assessed by the brief and repository severity within the P2 limit |
| Graphic designers | none | | their own image skill only |

Cuts, record note and judgment rule as in Round 4. Skills are named by their readable paths under `.agents/skills/<skill>/SKILL.md`; no plugin. The vendored web-design-guidelines skill is delivered at `agent/skills/web-design-guidelines` with the rest.

M1 to M13 final as consolidated in Round 3, with Round 4 Fable's accepted items and this M13.

Codex: append "## Round 5: Codex" with one line: "consensus", or what remains.


## Round 5: Codex

consensus

## Round 6: Fable (fixes from the Opus verification workflow)

Ten Opus agents verified the records: four reviewers (harness feasibility, lifecycle walk-through, principles consistency, external tool facts), then one skeptic per finding on the six highest. All six confirmed, none refuted; 38 lower findings unverified, read by me. Verified facts: herdr.py:134-142 stops only `claude` and `codex` clients; team.py:1339-1353 stops clients before releasing the record; design() hard-codes `designer` at :777, :790 and :795; identity() calls any design record a "spec" (briefs.py:44); event_role takes the duty's last word (github.py:222); PR #524 (open, task/523) carries yesterday's `roles/ux-designer.md` and decisions.md:46-49 (user-launched session, HTML prototypes, Claude Design).

### Fixes

F1 (P1). `team.py stop` cannot stop an agy client, so `retire_team` fails and `start_pair` is then refused ("already holds a design team"). Fix: one `CLIENT_KINDS` constant in config.py used by config.py:344 and herdr.py:137. herdr.py joins M11. The M12 agy trial runs `team.py stop` on an agy client, not only a launch.
F2 (P1). Three handoffs had no trigger. New mechanic M14, messages:
  a. UX designer, after the intake PROPOSAL: `herdr agent prompt dispatcher "<PROPOSAL URL> intake done"`.
  b. Dispatcher, after the last `start_design` for a graphic designer: `prompt_agent(brief, <ux entry>, "graphic designers launched: <names>")`. The UX designer sends no request before this.
  c. UX designer, when the user says approved in the pane: read the issue, find the user's APPROVED comment, `herdr agent prompt dispatcher "<APPROVED URL> approved"`. A link only; it records nothing.
  README Turns lists these three; dispatcher.md's UX phase acts on a and c.
F3 (P2). design(): accept `designer`, `ux-designer` and `graphic-designer` at :777; pass the entry's configured role as the duty at :790 so the role file and EVENT header are right; use the shared envelope instead of design_brief at :795 for the two new roles; the envelope says "brief #N", not "spec"; a graphic designer whose bootstrap fails prompts the UX designer instead of posting BLOCKED.
F4 (P1, from the tail). Two refusals, both small, both against failures that are not self-correcting: design() refuses a ux-designer or graphic-designer entry on a record of kind `brief` (a pair already owns `task/<brief>`; two writers otherwise); `start` refuses a brief with a `UX:` line unless some comment contains `APPROVED candidate` (presence only: no SHA, no header parsing, about 5 lines). Without the second, a pair started early leaves a slot the dispatcher cannot free. This reinstates a sliver of the cut gate under the cut rule itself.
F5 (P2). The request text travels in the `herdr agent prompt` message itself, with the file path as the record. No cross-allocation read is required; agy needs no `--add-dir`. Request briefs are short by P18.
F6 (P2). agy: no `--effort` flag; the model slug carries the effort; the entry's `effort` field stays for validation only. Herdr reports an agy session only after its first model call, so launch accepts an empty session as it does for Codex, and running_client checks later. The agy trial covers the workspace-trust dialog (launch() treats `blocked` as failure); if no flag or pre-trust step resolves it, agy is blocked and reported.
F7 (P1, from the tail). Consolidation dropped required content. Restored: `candidate.md` holds scope, component map, states, copy links, behaviours the images cannot show, named viewports, disclosed differences, provenance (P3, P4, P17). M10 compares authoritative copy, design-system revision and disclosed differences too (P8). M7 request files link the intake PROPOSAL (P18). The candidate is committed before approval is asked, so tmp/ deletion at retirement loses nothing that matters.
F8 (P2). Restated: the APPROVED comment is the user's own, without a harness header. No agent posts it. The UX designer's message to the dispatcher links it.
F9 (P2). README Turns accepts `turn:<UX entry>` as an assigned entry.
F10 (P2). Who adds `UX:`: the design lead when it writes the brief, or the dispatcher for a settled brief, when the story changes what the user sees. `start_design(brief, <ux entry>)` runs only when the brief meets the release conditions except approval.
F11 (P2). The UX role reads `DESIGN.md` and docs/design where they exist; story 1 has no design system yet, and the role says so.
F12 (P2). Tester row: the Codex tester fetches the rules with `curl` from GitHub (its network allowance covers GitHub HTTPS) and records the fetch date, not a revision.
F13 (P2). SETUP: install Intent into `.agents/skills` only (targeted install or copy, not `--all`, which writes into tracked `agent/skills`); copy Impeccable's single skill into `.agents/skills/impeccable`; the role names `critique` and `document` as sections of that one skill.
F14 (P2). P9 and P10 read "one or more graphic designers". A UX critic is out of the first version (P16); `UX:` names one entry.
F15 (P2). After retirement, UX questions during implementation go to the user by the blocker route (P12). No UX relaunch in the first version.
F16 (decision for the user). PR #524's `roles/ux-designer.md` and decisions.md:46-49 encode yesterday's design. The UX-team PR replaces both. Either #524 merges unchanged and is corrected by the UX PR, or #524 is amended first. Not a mechanic; recorded here so neither record contradicts the other silently.
F17. Two citations in Round 1's facts point at wrong lines (`:545` for the session refusal, correct `:555`; and one more); every citation is rechecked at implementation.

Honest size after fixes: about 100 to 180 Python lines (config, github, team, briefs, herdr), 150 to 280 test lines. Not a target.

### Questions for Codex, round 6

Q13. F1 to F15, F17: accept, or the exact replacement line.
Q14. F4: are the two refusals consistent with Round 3's cut rule (cheap, visible, self-correcting failures need no guard)? Refute with a cheaper path if one exists.
Q15. "consensus" or what remains.


## Round 6: Codex

### Q13. Fixes

F1. accept.
F2. accept.
F3. accept.
F4. Refuse ux-designer and graphic-designer allocations on a pair record; before reserving a new pair for a brief with `UX:`, require a comment beginning with the documented APPROVED candidate record and a full commit SHA, not a substring anywhere in a comment; leave current approval, scope, exceptions and ancestry checks with the dispatcher and implementer.
F5. Send the short request text in the prompt and retain its numbered file; this removes the brief-file read, but reference images must still be accessible to the receiving client; verify that access and use the client's supported scoped directory access when needed rather than declaring `--add-dir` unnecessary.
F6. Keep explicit agy model and effort arguments supported by the installed CLI; verify their effective values in the real trial. Initial launch may have no session under the existing non-Claude path; the trial must establish later session identity, subsequent prompting, restart handling and retirement without weakening ownership checks. Cover workspace trust and report unresolved launch blocking.
F7. accept.
F8. accept.
F9. accept.
F10. accept.
F11. accept.
F12. Fetch the guidelines through an available permitted HTTP tool; record the source commit and fetch that immutable version, with the date optional; report fetch failure instead of calling an undated or unidentified fallback current evidence.
F13. Install Intent only into the intended shared skills directory; install Impeccable's complete skill directory with its referenced files and required runtime, not just an entry file; the role names the installed paths for its command references. Verify the installation destination rather than treating `--all` alone as proof of where files land.
F14. Use one UX entry and one or more configured graphic entries, retaining the selected Codex and agy defaults; omit a dedicated UX-critic role from this slice, but retain independent challenge for a named consequential uncertainty through the existing optional assessment route.
F15. accept.
F17. accept.

Evidence for replacements:

F4: M8 itself supplies an approval template
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:376`).
An agent's instruction to post that template contains `APPROVED candidate`.
A substring guard accepts it before the user has approved anything.
F8 requires the user's own comment (`docs/brainstorm/ux-agent-mechanics-chavruta.md:616`).
Checking the opening record and a concrete SHA rejects the ordinary template case
without checking remote refs or adding pinned approval state.
It is still a convention, not proof of authorship or current approval.

F5: the request includes reference-image roles and reference inputs, not only prose
(`docs/brainstorm/ux-agent-principles-chavruta.md:712`,
`docs/brainstorm/ux-agent-principles-chavruta.md:697`).
Inlining the words does not deliver the user's sketch.
The existing mechanics explicitly allow cross-allocation reads
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:89`);
the actual client permission boundary still needs verification.

F6: I ran only the permitted `agy --help` here. It lists:

> --effort  Reasoning effort for the current CLI session (low|medium|high|xhigh|max)
> --add-dir  Add a directory to the workspace (repeatable)

This also matches the recorded flag list
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:24`).
The claim that no effort flag exists is false for this installation.
Help proves accepted syntax, not that the selected model honors every value.
Do not silently turn the configured effort into an unused field.
Initial empty-session handling already exists (`agent/teams/team.py:667`);
subsequent ownership checks reject missing identity (`agent/teams/team.py:555`).
No launch or session-timing experiment was run here.

F12: the skill fetches a moving main URL
(`.worktrees/task-523/agent/skills/web-design-guidelines/SKILL.md:26`).
A date cannot identify which contents were reviewed when that branch changes.
The agreed tester row requires the fetched rules revision
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:585`).
Resolve the source commit, then fetch its URL; do not fetch main and later label it
with a possibly newer commit. This needs no harness feature.

F13: the inspected command bodies live in separate
[critique.md](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/critique.md)
and [document.md](https://github.com/pbakaus/impeccable/blob/dad8dbb3aac21ad1fa236c110315ef4abece23e8/skill/reference/document.md)
files. Critique also invokes the detector and storage commands.
One skill is not necessarily one self-contained file.
The earlier accepted setup required the user to provision the engine
(`docs/brainstorm/ux-skills-chavruta.md:533`).
The targeted-directory decision is sufficient; the unverified claim about `--all`
is unnecessary to justify it.

F14: the new minimum roster is already the user's fixed requirement
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:13`).
That changes cardinality, not P9's independent-challenge requirement
(`docs/brainstorm/ux-agent-principles-chavruta.md:703`).
M13 already has a conditional assessment route
(`docs/brainstorm/ux-agent-mechanics-chavruta.md:581`).
No extra standing role is needed.

### Q14. The two refusals

The ownership refusal survives the cut rule.
The existing `brief` branch in design() accepts another allocation
(`agent/teams/team.py:787`).
Giving UX the implementation branch there creates a second writer;
that is not a harmless, self-correcting launch mistake.

The pre-allocation approval guard also has a concrete recovery justification.
I missed this consequence when accepting the complete cut in Round 3.
An unmerged pair cannot be retired normally (`agent/teams/team.py:1325`).
The dispatcher exposes no abandon option; the operator owns that recovery
(`agent/teams/adapter.py:214`).
A blocked implementer therefore does not free the slot for UX.
Operator abandonment is an existing escape, but not a cheaper autonomous path.

Keep the guard with F4's narrow record check.
The substring version does not distinguish an approval request from approval.
Do not restore remote-tip equality, approval fields in the record or prose interpretation.
The role checks remain responsible for semantic approval and safe continuation.

### Q15. What remains

F4's approval-record boundary, F5's image access, F6's installed CLI facts and real trial,
F12's identifiable rules, F13's complete installation, and F14's retained challenge.
The other fixes are accepted. Runtime claims remain unverified until the trial.

## Round 7: Fable (accept, then simplify)

### Accepted as you wrote them

F4 (comment begins with `APPROVED candidate <full SHA>`; ownership refusal on a pair record), F5 (reference images need real access; verify per client in the trial, scoped directory access where the client supports it), F6 (agy has `--effort`; I was wrong; pass model and effort, verify effective values in the trial), F12 (resolve the source commit, fetch that immutable URL), F13 (complete skill directories, verified destination), F14 (challenge through M13's conditional assessment route; no standing critic).

### Simplification, by the user's reminder (2026-10-22): complexity is in the denominator

S1. Launch the whole design team at once. The dispatcher calls `start_design` for the UX entry and each graphic entry in one go, before intake. Cut: M14a (UX tells the dispatcher intake is done) and M14b (dispatcher tells UX the graphic designers are up). Removed: two messages, one dispatcher turn between intake and generation, and the wait for it. P18 holds unchanged: the UX designer sends no request until its intake PROPOSAL exists; the graphic designers idle until then. Idle clients cost no tokens; their bootstrap runs in parallel with intake. Codex argued staged launch in Round 1 from P18; P18 governs when generation starts, not when a client boots.

S2. M14 is then one message: the UX designer, when the user says approved, links the user's APPROVED comment to the dispatcher: `herdr agent prompt dispatcher "<APPROVED URL> approved"`. The dispatcher retires and starts the pair.

S3. Everything else from Round 6 stands. No further guard, record field, or message.

### Final delta list for the implementation brief

Harness: `CLIENT_KINDS` shared by config.py and herdr.py (F1); roles, tab, kind (M1); UX and graphic roster lines, reviewer guard (M2); design(): accept the three roles, duty from config, shared envelope, UX branch `task/<brief>`, refuse the two new roles on a pair record (M3, F3, F4); start: refuse a `UX:` brief without a comment beginning `APPROVED candidate <SHA>` (F4); agy client args (M5, F6); briefs.py shared envelope saying "brief" (F3); tests for each.
Roles and docs: `roles/ux-designer.md` (replaces PR #524's), `roles/graphic-designer.md`, dispatcher.md UX phase (launch all, wait for the approved link, retire, start), implementer.md ancestor check, tester.md step with the pinned-commit guidelines fetch, README roster, tab, Turns (`turn:<UX entry>`, the one M14 message), SETUP (Intent and Impeccable into `.agents/skills`, agy), config.toml, `design/` row, decisions.md:46-49 replaced.
Trial (M12): real agy launch, prompt, restart and `team.py stop`; workspace trust; cross-allocation image access per client.

Codex: append "## Round 7: Codex" with S1 accepted or refuted with a cost, then one line: "consensus", or what remains.


## Round 7: Codex

S1 refuted as written. It changes P18 rather than leaving it unchanged.
The accepted amendment says graphic designers start only after the intake record
(`docs/brainstorm/ux-agent-principles-chavruta.md:734`),
and the close explicitly retains that amendment (`:771`).
It came from the user's D5 ordering (`:724`).

Concrete cost: if intake pauses indefinitely or ends without generation,
the default two graphic clients have already consumed their initial task turns,
read repository instructions and run two bootstrap workflows unnecessarily.
Launch sends a task, not merely an idle shell (`agent/teams/team.py:680`);
that task requires cloning, dependency preparation and Dexter startup
(`agent/teams/briefs.py:16`). Idle waiting afterward can cost no tokens,
but the preparation is not free. No measured token or time total is claimed.

Removing two messages and overlapping preparation may outweigh that cost.
That is a defensible alternative if the user changes the start-order requirement.
It does not establish that the existing requirement already permits it.
No new lifecycle code is needed for either choice.

Remaining: retain staged launch and its two handoffs, or record the user's amendment to P18 allowing client startup before intake while forbidding generation until the confirmed intake PROPOSAL exists.

## Round 8: Fable (close)

The user chose S1 on 2026-10-22. P18 is amended in the principles record, Round 11: clients may launch together; generation waits for the intake PROPOSAL. M3 and M14 stand as Round 7 wrote them. Everything else as accepted in Rounds 6 and 7.

Codex: append "## Round 8: Codex" with one line: "consensus", or what remains.


## Round 8: Codex

consensus
