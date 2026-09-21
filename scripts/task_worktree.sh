#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <issue>-<slug> [--force]" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage
[[ $1 =~ ^[0-9]+-[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage
force=false
if [[ $# == 2 ]]; then
  [[ $2 == --force ]] || usage
  force=true
fi

main_checkout=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if [[ $(pwd -P) != "$main_checkout" ]]; then
  echo "Run this script from the main checkout: $main_checkout" >&2
  exit 1
fi
if [[ ! -d "$main_checkout/.agents/skills" ]]; then
  echo "Missing skills directory: $main_checkout/.agents/skills" >&2
  exit 1
fi

worktree="$main_checkout/.worktrees/$1"
branch="task/$1"
if [[ ! -e "$worktree" ]]; then
  git fetch origin
  git worktree add -b "$branch" "$worktree" origin/main
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
printf 'After Astra exits and its pane is back at the shell, run:\n'
printf 'herdr agent start astra --kind codex --pane wJ:p2 -- -C %q\n' "$worktree"
