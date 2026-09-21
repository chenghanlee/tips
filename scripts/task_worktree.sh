#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/task_worktree.sh <issue>-<slug> --team N --pane <pane-id> [--agent <name>] [--force]

  --team N       team number 1-5; selects the port and database block
  --pane ID      Herdr pane that will run the developer's Codex (from `herdr agent list`)
  --agent NAME   Herdr agent name for the developer (default: team-N-dev)
  --force        replace a differing .codex/config.toml in the worktree
USAGE
  exit 1
}

[[ $# -ge 1 ]] || usage
task=$1
shift
[[ $task =~ ^[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage
force=false
team=""
pane=""
agent=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --team) [[ $# -ge 2 && $2 =~ ^[1-5]$ ]] || usage; team=$2; shift 2 ;;
    --pane) [[ $# -ge 2 && $2 =~ ^w[A-Za-z0-9]+:p[A-Za-z0-9]+$ ]] || usage; pane=$2; shift 2 ;;
    --agent) [[ $# -ge 2 && $2 =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || usage; agent=$2; shift 2 ;;
    --force) force=true; shift ;;
    *) usage ;;
  esac
done
[[ -n $team && -n $pane ]] || usage
[[ -n $agent ]] || agent="team-${team}-dev"

main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if [[ $(pwd -P) != "$main_checkout" ]]; then
  echo "Run this script from the main checkout: $main_checkout" >&2
  exit 1
fi
if [[ ! -d "$main_checkout/.agents/skills" ]]; then
  echo "Missing skills directory: $main_checkout/.agents/skills" >&2
  exit 1
fi

worktree="$main_checkout/.worktrees/$task"
branch="task/$task"
if [[ ! -e "$worktree" ]]; then
  git fetch origin
  git worktree add --no-track -b "$branch" "$worktree" origin/main
elif [[ $(git -C "$worktree" rev-parse --show-toplevel) != "$worktree" ||
        $(git -C "$worktree" branch --show-current) != "$branch" ||
        $(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir) != "$main_checkout/.git" ]]; then
  echo "Refusing to reuse a path that is not this repository's $branch worktree: $worktree" >&2
  exit 1
fi

skills="$worktree/.agents/skills"
if [[ -e "$skills" && ! -L "$skills" ]]; then
  echo "Refusing to replace existing skills: $skills" >&2
  exit 1
fi

mkdir -p "$worktree/.codex" "$worktree/.agents"
config="$worktree/.codex/config.toml"
template=$(mktemp "$worktree/.codex/config.toml.XXXXXX")
trap 'rm -f "$template"' EXIT
# JSON string escaping also produces a valid TOML basic string for this path.
quoted_worktree=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$worktree")
cat > "$template" <<EOF
[plugins."mix-compile@elixir-agent-tools"]
enabled = true
[plugins."mix-credo@elixir-agent-tools"]
enabled = true

[mcp_servers.elixir-lsp]
command = "/bin/sh"
args = ["scripts/elixir_lsp.sh"]
cwd = $quoted_worktree
startup_timeout_sec = 60
tool_timeout_sec = 120
enabled_tools = ["definition", "references", "hover", "diagnostics"]
EOF

if ! cmp -s "$template" "$config"; then
  if [[ ( -e "$config" || -L "$config" ) && "$force" != true ]]; then
    echo "Refusing to overwrite $config; inspect it, then use --force to replace it." >&2
    exit 1
  fi
  mv -f "$template" "$config"
fi
if [[ ! -L "$skills" || $(readlink "$skills") != "$main_checkout/.agents/skills" ]]; then
  ln -sfn "$main_checkout/.agents/skills" "$skills"
fi

printf 'Worktree: %s\n' "$worktree"
printf 'Developer environment: PGPORT=5433 TIPS_DB_SUFFIX=_t%s TIPS_TEST_PORT=41%s0 MIX_ENV=test\n' "$team" "$team"
printf 'Tester environment:    PGPORT=5433 TIPS_DB_SUFFIX=_t%sr TIPS_TEST_PORT=41%s1 MIX_ENV=test\n' "$team" "$team"
printf 'Tech lead environment: PGPORT=5433 TIPS_DB_SUFFIX=_t%sl TIPS_TEST_PORT=41%s2 MIX_ENV=test\n' "$team" "$team"
printf 'After %s exits and pane %s is back at the shell, run:\n' "$agent" "$pane"
printf 'herdr agent start %s --kind codex --pane %s --timeout 120000 -- -m gpt-6-sol -c model_reasoning_effort=xhigh -C %q\n' "$agent" "$pane" "$worktree"
