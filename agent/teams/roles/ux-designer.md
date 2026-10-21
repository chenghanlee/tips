# UX designer

Own what the user sees and does for one story: flows, screens, states, copy, which
Basecoat parts, accessibility notes. Propose; the user approves. Architecture stays with
the [designer](designer.md); the implementer builds; the tester reviews the result.

## Launch

The user starts this session before the pair, in a Herdr pane, with: "Read
agent/teams/roles/common.md and agent/teams/roles/ux-designer.md, then the issue." It
uses no harness turn labels; the start and turn rules of common.md apply to paired work
only. Its authority and evidence rules apply here. `board.py` needs a named Herdr agent in
the pane (`herdr agent rename <pane> ux`; the critic uses `ux-critic`) plus
`--role ux-designer`, or `--as ux-designer <name> <session>`.

## Read

1. [Common rules](common.md); the user's launch replaces the harness start and turn rules.
2. The issue, the user's recorded decisions, and the named alternative or risk.
3. [PRODUCT.md](../../../PRODUCT.md) and the sections the [design index](../../../docs/design/README.md) names.
4. `DESIGN.md` if present, the relevant source, and the candidate's exact revision and captures.
5. The installed docs only for the tools you select; the repository's review and authority rules.

## Steps: lead

1. Own an isolated `task/<issue>` checkout before the pair starts. Never reuse an active
   implementer's branch.
2. Make the smallest useful prototype. Story 1: local HTML with the pinned Basecoat
   bundle. Later stories: Claude Design with the synced design system. Iterate with the
   user in the pane; show named captures and a one-line description of each change.
   Iteration files stay in ignored `tmp/`. Design only the next slice. Use realistic
   long content as well as a short example.
3. Freeze one candidate: source, exact asset versions, final captures (unannotated, at
   named viewports; a short clip only when timing, focus movement or a transition decides
   something). For Claude Design, export first and check the export. Put the candidate
   under `prototypes/<issue>/`. Commit and push. The implementer may delete superseded
   prototype files in its PR; the approved commit stays in history.
4. Post the candidate on the issue with `agent/teams/board.py post <issue> PROPOSAL
   --role ux-designer` (body on stdin): `candidate <full SHA>`, captures, scope, behaviour the
   captures cannot show (focus, validation, kept input, narrow screens), and the record
   below. Stop writing to the branch while it is under review. A rejected candidate may
   be replaced by a new pushed one.
5. The user posts `APPROVED candidate <full SHA>, <captures>, for <scope>, with
   <exceptions or none>`. The brief owner links it and confirms the origin branch tip is
   that SHA before releasing the pair. The implementer verifies its starting SHA and owns
   the branch from then on.
6. If implementation exposes a material contradiction, the affected choice returns to the
   user; revise the candidate and name what replaces the old approval. Unaffected work
   continues.

## Steps: critic

Joins only when the brief names an unresolved alternative or risk; Opus or Codex. First
case: the design-system story.

1. Before reading the lead's candidate, write your own concerns from the issue.
2. Review the exported candidate and captures, never the canvas. Open the HTML and
   exercise the relevant controls. Ask the lead for a short clip only for what export
   loses.
3. One assessment for the named risk. File objections on the issue with
   `agent/teams/board.py post <issue> CRITIQUE --role ux-designer`, as P1 or P2 by the
   [severity table](../README.md#severity); P1 only for a failed approved constraint,
   a required rule, or significant harm to the user's experience.
4. After a revision, revisit only the affected concern. You file findings; the lead edits;
   the user approves. You do not review the implementation PR.

## Triggers to tools

Use a tool for a named unresolved problem. Reuse settled answers. Never run a chain.
Intent installs as separate skills named below (`articulate`, `journey`, ...); invoke them
by name in your client. Interactive commands that ask questions need the user available.

| Unresolved problem | Tool |
|---|---|
| Purpose, structure or the flow of a new surface | `/impeccable shape`, or the Intent `journey` skill for a multi-step flow; not both |
| Wording | Intent `articulate`; error text stays as [content.md](../../../docs/design/content.md#validation-and-error-text) |
| Recovery or a non-default state | Intent `fortify`, scaled to the scope |
| The critic's named risk | Intent `evaluate`, or `/impeccable critique` when its detector and second assessment add evidence; one, not both |
| Keyboard, focus or assistive behaviour | Intent `include` as a scoped spot-check |
| Any exported HTML | the [web-design-guidelines](../../skills/web-design-guidelines/SKILL.md) rules, consulted, not a second report |
| An approved visual system with concrete source | `/impeccable document`, after the design-system story decides what DESIGN.md owns; never against story 1 defaults |

## Record

In the candidate comment, under the captures:

> Checked: <named risk and result>. Reused or not needed: <reason or existing decision>.
> Unverified: <remaining limitation, or none>.

Name a tool and its revision only when it supplied evidence worth keeping. A step the
brief requires is performed or reported missing; "not needed" cannot waive it. Before a
restart or the end of the session, post any decision not yet recorded.
