# Agent teams: setup

Humans: perform setup from the repository root. Agents use the [operating agreement](README.md) and their role card during events; no setup reading is needed.

## One-time setup

Install Python 3.12 and [configured client CLIs](config.toml). Authenticate clients and GitHub CLI (`gh`) for this repository. Merges require GNU `timeout` on `PATH`: macOS `brew install coreutils`; Linux distribution `coreutils` package. Coding agents also need `unbuffer` (Expect): the Elixir skill requires it on Mix commands.

The user maintains third-party skills in the main checkout. Both native locations are Git-ignored:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban`, `herdr`, `grill-me` and `grilling`, for Codex.
- `.claude/skills/`: the same five Elixir skills, `grill-me` and `grilling`, for Claude.

Before using the [brief consensus workflow](README.md#brief-consensus), install `grill-me/SKILL.md` and `grilling/SKILL.md` in both skill directories above. Copy the existing grilling instructions into each `grilling/SKILL.md`. Keep the wrapper's frontmatter, but replace its Skill-tool-only body with `Read and follow the grilling skill from ../grilling/SKILL.md.` This explicit relative path works without assuming a native Skill tool. These user-owned files are ignored and are not installed by this PR. Verify `/grill-me` in Claude Code and `$grill-me` in Codex load both files, rather than merely accepting the prompt.

Grilling uses direct Herdr messages and needs no shared discussion directory or additional filesystem allowance. Existing discussion history can stay; this workflow does not change user-owned permissions.

Before live teams use this workflow, run a disposable pilot using the configured clients in helper-provisioned worktrees. Repeat after skill, client-setting or client-version changes. Use the documented assignment and invocation unchanged except for actual issue, SHA and agent targets; do not add coaching absent from the workflow. Record each role's actual client kind, model and version, session, worktree and SHA on the setup or change issue/PR. Verify both Claude and Codex load `grill-me` and `grilling`; record the exact paths, including any user-level copy that shadows the project skill.

The pilot must exercise:

- Preparation before the short skill-plus-prompt invocation; the named lead is the respondent.
- A numbered round of ten questions delivered completely to the lead through Herdr, and a complete long answer round sent back to the worker. Verify apostrophes, backticks and dollar signs arrive literally and answers are acted on.
- An answer that opens a dependent contract question: the worker sends it to the lead. Also test answers that open nothing: the worker reports shared understanding without manufactured questions.
- Changed decisions after one worker agreed: send the changes directly to that worker for reconsideration. Both workers then acknowledge the same final revision before release.
- Direct question and answer messages without polling, recovery by resending missing message content, and the same conversation between lead TPM and tech lead.
- Context recovery: compact one worker of each client while a decision is unresolved. It rereads what [Events](README.md#events) requires, keeps the open decision, and its next action respects it. Rereading and then ignoring the open decision is a failure.

Send questions and answers directly through Herdr, with no file or document-link handoffs during the interview. Record failures and unresolved limits; do not substitute documentation checks for this pilot or assign live implementation through an unverified flow.

Update matching copies together, then check that the skills appear in each client's skill list. Provisioning links the main checkout's `.agents/skills/` into each worktree and checks only that the directory exists, not the individual skills.

### Repository skills

`agent/skills/` owns `github-comments`, `test-desiderata` and `dexter`. Both clients
load main-checkout bodies through native links. Worktrees share main's skills;
a branch editing a skill does not isolate its native version. Provisioning still
links the whole `.agents/skills` directory; no helper change is needed.

Pass the candidate pilot below before merging. With teams idle, merge and install
in the same sitting, then start fresh sessions: live sessions retain old skill
lists. The PR must name installation as a merge step. Until installation, native
Dexter still points at the old copy. Only the user runs these commands in the real
main checkout. They preserve previous entries under ignored `tmp/`, outside native
discovery, and leave other skills alone. Do not change skills under live agents.

Run from the main checkout root after the three tracked bodies exist:

```bash
python3 - <<'PYINSTALL'
from pathlib import Path
import os
import tempfile

root = Path.cwd()
names = ('github-comments', 'test-desiderata', 'dexter')
folders = (root / '.agents/skills', root / '.claude/skills')
for name in names:
    assert (root / 'agent/skills' / name / 'SKILL.md').is_file(), name
for folder in folders:
    assert not folder.parent.is_symlink() and not folder.is_symlink(), folder
    assert not folder.exists() or folder.is_dir(), folder
(root / 'tmp').mkdir(exist_ok=True)
backup = None
for folder in folders:
    folder.mkdir(parents=True, exist_ok=True)
    for name in names:
        entry = folder / name
        target = '../../agent/skills/' + name
        if entry.is_symlink() and os.readlink(entry) == target:
            continue
        if entry.exists() or entry.is_symlink():
            if backup is None:
                backup = Path(tempfile.mkdtemp(prefix='skills-before-install-', dir=root / 'tmp'))
                print('Saving previous entries under', backup, flush=True)
            saved = backup / folder.parent.name / name
            saved.parent.mkdir(parents=True, exist_ok=True)
            entry.rename(saved)
        entry.symlink_to(target, target_is_directory=True)
PYINSTALL
```

Check both clients list all three names once and load the tracked bodies. To roll
back, remove only the three links created above and move saved entries back to
their original locations; restart sessions. Never delete a replacement folder
that someone has since installed.

### Skill pilot

Use a separate clone outside the real repository tree at the candidate head.
Install the native links there with the same commands. Link existing Elixir and
grilling skill folders into the clone without editing their contents. Add a
worktree under the clone's `.worktrees/` and link its `.agents/skills` to the
clone's directory, exactly as provisioning does. Run worker tasks there. This
tests nested links and Claude parent discovery without the real main's stale copy.

Use the configured Claude and Codex models from `config.toml`; record client,
model and version. Run three ordinary prompts per client: add a test, find a
function's callers, and draft a review into `tmp/review.json` without posting.
Prompts must not name skills, Dexter, testing policy or writing style. After a
load, compact each client's session and give a second task of the same kind.
Do not replace compaction with a new session or a hand-written summary.

Define failures before running:

- Tests: test design, edits or a review verdict before loading the skill body.
- Dexter: source navigation covered by its operation table before loading the
  body, with any tool. Literal-text search is not a navigation miss.
- Comments: drafting a comment or review body before loading the skill, or a
  draft that lists routine passing checks. A passing result that explains a
  finding or repair is not an inventory.
- Discovery: missing or duplicate names, stale bodies, broken repository paths,
  or Codex failing to follow the nested links.

Record transcript order, body paths/content and native-entry versus AGENTS.md
path loads. The route does not establish which context triggered it. Keep all
three native entries. Verify review format against `reviews.md`, omit repeated
diff descriptions and passing-check inventories, and compare length with one
recent comparable comment. No mandatory Dexter `Ran:` line: self-reports are not
tool-use evidence, and reviewers may lack worker traces.

A miss blocks promotion of that skill. Allow at most two corrections; rerun the
failed case plus one different case each time. After two failed corrections,
restore that skill's prior always-loaded policy and report the failed extraction.
Mixed results are allowed. Investigate topology only when evidence implicates it;
a trigger miss alone does not justify rewriting provisioning. Eight single runs
show no observed miss, not reliable adherence or measured token savings.

Install only the `mix-credo` plugin, for the clients you use:

```bash
# Codex
codex plugin marketplace add georgeguimaraes/elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code
claude plugin marketplace add georgeguimaraes/elixir-agent-tools
claude plugin install mix-credo@elixir-agent-tools
```

Generated settings enable Credo for both clients. Run explicit Mix checks after edits. Follow plugin trust prompts. Claude launches use `--settings` to disable known language-server plugins, including in linked worktrees; existing local settings files are preserved. Remove any old `mcp_servers.elixir-lsp` entry from Codex configuration; launchers do not disable it. Unrelated MCP servers remain available in coding sessions.

Build Dexter with the [LSP guide](../lsp/README.md#build): the pinned source plus the local patch, one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Provisioning selects the target worktree's Elixir version and binds the source path into the worktree's generated files. Keep the shared tools/sources independent of task worktrees.

Task and review checkouts use their own instruction files; the helper does not copy instructions. Before launching on a new shared Dexter build, verify that the assigned revision has compatible instructions. Stop teams before replacing the shared build, then re-provision.

Codex must be allowed to connect to Dexter's local Unix socket. The tested macOS `workspace-write` sandbox denies it with network access disabled; the reviewer verified access with network access enabled or a scoped `--allow-unix-socket /private/tmp/dexter-<uid>` sandbox allowance. Check the installed Codex sandbox options and set the narrowest suitable user-owned permission before first launch. With approval policy `never`, a denied connection cannot escalate. The launcher does not change sandbox settings.

## Starting the lead TPM

Run every lifecycle command in a Herdr terminal (`HERDR_ENV=1` set by Herdr) from the main checkout. During setup, handle each client's repository trust prompt. Unexpected approval prompts stop a launch; inspect them and follow the active approval policy. Launchers never edit home-directory trust settings.

```bash
agent/teams/team.py start lead
```

Do not run it while another live agent owns `lead-tpm`. The lead TPM starts and retires teams from this checkout; coding panes remain shells until assigned. Once ready, send a short assignment such as `Read issue #74 and launch one team for it`; keep the detailed assignment on the issue. Follow the [assignment and handoff convention](README.md#shared-rules), not a pasted copy of the full instructions.

## Configuration

Edit [config.toml](config.toml): team limits; client/model/effort per role; port/database allocation; permissions; coordinator compaction; time budgets. Scripts read the canonical main checkout's file. Use `TIPS_TEAM_CONFIG=/absolute/path` for staged configuration in a disposable pilot. Settings apply next launch. `timeouts.dexter_startup_seconds` bounds the index wait of the provisioning warm-up; it does not require rebuilding Dexter. The same value limits Elixir version detection and the daemon stop at retirement: a run that exceeds it is ended, even a valid slow one. `roles.lead_ui` sets the client, model and effort only; a UI lead uses `roles.lead`'s port and database.

Claude and Codex both use the generated `$TIPS_DEXTER` command from their shell tool.
Existing shell approval and sandbox policies remain in force; no permission exception
is added. Claude uses the configured permission mode. The lead TPM runs without Dexter;
coding launches do not inherit its compaction setting.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, team number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + team number × `team.port_stride` + role `port_offset` |

Generated worktree files point at the shared Dexter binary; reviewed revisions need not contain the build. The helper warms up Dexter even when invoked without `--start`; it fetches locked dependencies first for a new checkout or a review head, and leaves a resumed developer worktree's dependencies alone. For staged pilots, `TIPS_DEXTER_HOME` selects the shared build directory. Configuration/tooling changes require disposable pilots verifying both the client root and the `TIPS_DEXTER` root in each actual client. Before scaling, measure simultaneous cold-start capacity; configured team limits do not verify it.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no teams running. Agent launch settings never restart PostgreSQL or existing clients.

## Check changes to these scripts

Follow [Changing agent/teams scripts](development.md#changing-agentteams-scripts): check commands, CI evidence, test constraints and `# noqa: S603` limits. [pyproject.toml](pyproject.toml) uses the harness's Python profile: strict types, complexity limit 10, same lint rules. Only Python files under `tests/` get the test-assertion exception. For optional local developer checks, install Ruff/Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Milestones, gate issues and dev-adapter policy live there, never mirrored here. Gates name environment, revision, evidence and unresolved blockers.
