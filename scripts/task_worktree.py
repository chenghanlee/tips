#!/usr/bin/env python3
"""Internal worktree provisioning and client launch for the team lifecycle."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid

from team import load_config, stop_agent


class Refusal(Exception):
    pass


def run(argv, *, timeout=None, env=None):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        raise Refusal(f"{shlex.join(map(str, argv))} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def git(*args):
    return run(['git', *map(str, args)])


def main():
    parser = argparse.ArgumentParser(description='Provision one task/reviewer worktree; --start launches its configured client in Herdr.')
    parser.add_argument('task')
    parser.add_argument('--team', required=True, type=int)
    parser.add_argument('--pane', required=True)
    parser.add_argument('--agent')
    parser.add_argument('--role', choices=['dev', 'lead', 'test'])
    parser.add_argument('--kind', choices=['codex', 'claude'], help='Must match the configured role kind')
    parser.add_argument('--review-ref')
    parser.add_argument('--start', action='store_true')
    parser.add_argument('--force', action='store_true', help='Replace differing selected-client configuration while no client is running')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+-[a-z0-9]+(?:-[a-z0-9]+)*', args.task):
        raise Refusal('Task must be <issue>-<slug>.')
    if not re.fullmatch(r'w[A-Za-z0-9]+:p[A-Za-z0-9]+', args.pane):
        raise Refusal('Invalid Herdr pane ID.')
    inferred = re.fullmatch(r'team-([0-9]+)-(dev|lead|test)', args.agent or '')
    role_name = args.role or (inferred.group(2) if inferred else 'dev')
    if inferred and (int(inferred.group(1)) != args.team or inferred.group(2) != role_name):
        raise Refusal('Agent name must match its requested team and role.')
    agent_name = args.agent or f'team-{args.team}-{role_name}'
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', agent_name):
        raise Refusal('Invalid Herdr agent name.')

    root = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir')).parent
    if Path.cwd() != root:
        raise Refusal(f'Run from the main checkout: {root}')
    config_path = Path(os.environ.get('TIPS_TEAM_CONFIG', str(root / 'config/agent-team.toml'))).resolve()
    _, config = load_config()
    team, timeouts, policies = config['team'], config['timeouts'], config['launch']
    role = config['roles'][role_name]
    kind = role['kind']
    if kind not in ('codex', 'claude') or (args.kind and args.kind != kind):
        raise Refusal('--kind must match the configured role.kind.')
    if not 1 <= args.team <= team['max_teams']:
        raise Refusal(f"Team must be between 1 and {team['max_teams']}.")
    # This is the installed bridge's compiled contract, not a configurable fallback.
    if timeouts['mcp_tool_seconds'] != 120:
        raise Refusal('The patched bridge has a compiled 120-second deadline. Rebuild and revalidate it before changing mcp_tool_seconds.')
    model, effort = role['model'], role['effort']
    port = team['port_base'] + team['port_stride'] * args.team + role['port_offset']
    if not 1 <= port <= 65535:
        raise Refusal('Configured role port is outside the TCP port range.')
    target_env = {
        'PGPORT': str(team['postgres_port']),
        'TIPS_DB_SUFFIX': team['db_suffix_prefix'] + str(args.team) + role['db_suffix'],
        'TIPS_TEST_PORT': str(port),
        'MIX_ENV': 'test',
        'TIPS_CHECK_TIMEOUT_SECONDS': str(timeouts['checks_minutes'] * 60),
        'TIPS_TEAM_CONFIG': str(config_path),
    }
    if 'compaction_percent' in role:
        target_env['CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'] = str(role['compaction_percent'])
    if os.environ.get('HERDR_ENV') != '1':
        raise Refusal('Run the worktree helper inside Herdr.')

    def herdr(*parts, timeout=None):
        text = run(['herdr', *map(str, parts)], timeout=timeout or timeouts['shell_seconds'])
        if parts[:2] == ('pane', 'run'):
            return {}
        value = json.loads(text)
        if 'error' in value:
            raise Refusal(str(value['error']))
        return value['result']

    issue = args.task.split('-', 1)[0]
    worktree = root / '.worktrees' / args.task
    branch = 'task/' + args.task
    existing_branch = False
    if not args.review_ref:
        branches = git('for-each-ref', '--format=%(refname:short)', f'refs/heads/task/{issue}-*').splitlines()
        if len(branches) > 1:
            raise Refusal(f'Ambiguous task branches for issue {issue}: {branches}')
        if branches:
            existing_branch = True
            branch = branches[0]
            records = [dict(line.split(' ', 1) for line in block.splitlines() if ' ' in line)
                       for block in git('worktree', 'list', '--porcelain').split('\n\n')]
            matches = [Path(record['worktree']) for record in records if record.get('branch') == 'refs/heads/' + branch]
            if len(matches) > 1:
                raise Refusal(f'Ambiguous worktrees for {branch}: {matches}')
            worktree = matches[0] if matches else root / '.worktrees' / branch.removeprefix('task/')
            if worktree.parent != root / '.worktrees':
                raise Refusal(f'Task branch belongs to a worktree outside the managed directory: {worktree}')
    wrapper = root / 'scripts/elixir_lsp.sh'
    if not wrapper.is_file() or not (root / '.agents/skills').is_dir():
        raise Refusal('Canonical LSP wrapper or shared skills directory is missing.')
    if args.start:
        tools = Path(os.environ.get('TIPS_ELIXIR_TOOLS', str(root / '.elixir-tools'))) / 'bin'
        for binary in ('mcp-language-server', 'expert'):
            if not os.access(tools / binary, os.X_OK):
                raise Refusal(f'Missing executable: {tools / binary}; run tool preflight first.')

    review_sha = git('rev-parse', '--verify', '--end-of-options', args.review_ref + '^{commit}') if args.review_ref else None
    old_head = None
    if worktree.exists():
        if (Path(git('-C', worktree, 'rev-parse', '--show-toplevel')) != worktree
                or Path(git('-C', worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir')) != root / '.git'):
            raise Refusal(f'Not this repository\'s worktree: {worktree}')
        current_branch = git('-C', worktree, 'branch', '--show-current')
        if review_sha:
            if current_branch:
                raise Refusal(f'Refusing an attached review checkout: {worktree}')
            if git('-C', worktree, 'status', '--porcelain', '--untracked-files=all'):
                raise Refusal(f'Refusing a dirty review checkout: {worktree}')
        elif current_branch != branch:
            raise Refusal(f'Worktree is not on {branch}: {worktree}')
        old_head = git('-C', worktree, 'rev-parse', 'HEAD')

    # Stage/check only the selected client's files before changing HEAD or stopping anyone.
    if kind == 'codex':
        desired = {worktree / '.codex/config.toml': f'''[plugins."mix-compile@elixir-agent-tools"]
enabled = true
[plugins."mix-credo@elixir-agent-tools"]
enabled = true

[mcp_servers.elixir-lsp]
command = "/bin/sh"
args = {json.dumps([str(wrapper), str(worktree)], ensure_ascii=False)}
cwd = {json.dumps(str(worktree), ensure_ascii=False)}
startup_timeout_sec = {timeouts['mcp_startup_seconds']}
tool_timeout_sec = {timeouts['mcp_tool_seconds']}
enabled_tools = ["definition", "references", "hover", "diagnostics"]
'''}

        for tool in ('definition', 'references', 'hover', 'diagnostics'):
            desired[worktree / '.codex/config.toml'] += (
                f'\n[mcp_servers.elixir-lsp.tools.{tool}]\n'
                f'approval_mode = {json.dumps(policies["codex_lsp_approval_mode"])}\n'
            )
    else:
        desired = {
            worktree / '.claude/settings.local.json': json.dumps({'enabledPlugins': {
                'mix-compile@elixir-agent-tools': True,
                'mix-credo@elixir-agent-tools': True,
                'elixir-lsp@elixir-agent-tools': False,
            }}, indent=2) + '\n',
            worktree / '.claude/elixir-mcp.json': json.dumps({'mcpServers': {'elixir-lsp': {
                'type': 'stdio', 'command': '/bin/sh', 'args': [str(wrapper), str(worktree)],
                'timeout': timeouts['mcp_tool_seconds'] * 1000,
            }}}, indent=2) + '\n',
        }
    if not worktree.exists() and not review_sha and not existing_branch:
        git('fetch', 'origin')

    # Generated configuration and shared skills must not overwrite tracked target content.
    target_tree = git('rev-parse', review_sha or old_head or (branch if existing_branch else 'origin/main'))
    selected = [path.relative_to(worktree).as_posix() for path in desired] + ['.agents/skills']
    for relative in selected:
        if git('ls-tree', target_tree, '--', relative):
            raise Refusal(f'Requested revision tracks generated path {relative}; preserving checkout.')
        parent = str(Path(relative).parent)
        entry = git('ls-tree', target_tree, '--', parent)
        if entry and not entry.startswith('040000 tree '):
            raise Refusal(f'Requested revision has a non-directory at {parent}; preserving checkout.')
    changed = []
    for path, content in desired.items():
        if path.is_symlink() or path.parent.is_symlink():
            raise Refusal(f'Refusing symlinked client configuration: {path}')
        if path.exists() and path.read_text() != content and not args.force:
            raise Refusal(f'Refusing to overwrite {path}; inspect it before using --force.')
        if not path.exists() or path.read_text() != content:
            changed.append(path)
    skills = worktree / '.agents/skills'
    if skills.exists() and not skills.is_symlink():
        raise Refusal(f'Refusing to replace existing skills: {skills}')

    agents = herdr('agent', 'list')['agents']
    owner = None
    for agent in agents:
        agent_root = agent.get('foreground_cwd') or agent.get('cwd')
        teammate = re.fullmatch(r'team-' + str(args.team) + r'-(dev|lead|test)', agent.get('name') or '')
        if teammate:
            teammate_issue = re.match(r'([0-9]+)-', Path(agent_root or '').name)
            if not teammate_issue or teammate_issue.group(1) != issue:
                raise Refusal(f'Team {args.team} already has a coding agent on another or unknown issue: {agent.get("name")} at {agent_root}')
        relevant = agent.get('pane_id') == args.pane or agent.get('name') == agent_name or agent_root == str(worktree)
        if not relevant:
            continue
        if (agent.get('pane_id') != args.pane or agent_root != str(worktree)
                or agent.get('agent') != kind or agent.get('name') not in (None, agent_name)):
            raise Refusal(f'Conflicting live agent: {agent.get("name") or agent.get("pane_id")} at {agent_root}')
        owner = agent
    if owner:
        if not old_head:
            raise Refusal('Live session has no matching Git worktree.')
        if changed:
            raise Refusal('Client configuration changed while its session is running; stop it before reconfiguring.')
        if not review_sha or review_sha == old_head:
            if owner.get('agent_status') in ('blocked', 'unknown'):
                raise Refusal(f'Existing session is {owner.get("agent_status")}; inspect its pane.')
            if args.start and not owner.get('name'):
                herdr('agent', 'rename', args.pane, agent_name)
            print(f'Already running: {agent_name} in {worktree} ({owner.get("agent_status")})')
            return
        if not args.start:
            raise Refusal('A reviewer is running; use --start to stop it safely before advancing its revision.')
        stop_agent(args.pane, str(worktree))
        # A final edit can have completed during client shutdown.
        if git('-C', worktree, 'status', '--porcelain', '--untracked-files=all'):
            raise Refusal('Review checkout became dirty during shutdown; preserving it.')

    if args.start or (old_head and review_sha and old_head != review_sha):
        info = herdr('pane', 'process-info', '--pane', args.pane)['process_info']
        foreground = info.get('foreground_processes', [])
        if not foreground or any(p['pid'] != info['shell_pid'] for p in foreground):
            raise Refusal('Target pane is not at its shell; nothing will be launched there.')
    if not worktree.exists():
        if review_sha:
            git('worktree', 'add', '--detach', worktree, review_sha)
        elif existing_branch:
            git('worktree', 'add', worktree, branch)
        else:
            git('worktree', 'add', '--no-track', '-b', branch, worktree, target_tree)
    elif review_sha and old_head != review_sha:
        git('-C', worktree, 'checkout', '--detach', '--no-overwrite-ignore', review_sha)

    for path, content in desired.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.read_text() == content:
            continue
        if path.exists() and not args.force:
            raise Refusal(f'Checkout introduced a conflicting config; preserving {path}')
        # Atomic per-file replacement, without a transaction or another lifecycle lock.
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
            temp = Path(stream.name)
            stream.write(content)
        try:
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)
    skills.parent.mkdir(parents=True, exist_ok=True)
    shared_skills = root / '.agents/skills'
    if not skills.is_symlink() or os.readlink(skills) != str(shared_skills):
        skills.unlink(missing_ok=True)
        skills.symlink_to(shared_skills)
    print(f'Worktree: {worktree}')
    if not args.start:
        print('Provisioned; use --start to launch this configured role.')
        return

    # Herdr is a separate server: caller-side exports do not configure the target shell.
    marker = 'TIPS_TASK_READY_' + uuid.uuid4().hex
    setup = 'cd -- ' + shlex.quote(str(worktree)) + ' && export ' + ' '.join(shlex.quote(k + '=' + v) for k, v in target_env.items())
    if 'compaction_percent' not in role:
        setup += ' && unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'
    # Never put the complete acknowledgment in terminal input, even when echoed.
    setup += " && printf '\\n%s%s\\n' " + shlex.join([marker[:16], marker[16:]])
    herdr('pane', 'run', args.pane, setup)
    herdr('pane', 'wait-output', args.pane, '--match', marker, '--source', 'detection',
          '--timeout', timeouts['shell_seconds'] * 1000)
    client = []
    if kind == 'codex':
        client += ['-a', policies['codex_approval'], '-C', str(worktree)]
        if model:
            client += ['-m', model]
        client += ['-c', 'model_reasoning_effort=' + json.dumps(effort)]
    else:
        client += ['--permission-mode', policies['claude_permission_mode'], '--effort', effort,
                   '--mcp-config', str(worktree / '.claude/elixir-mcp.json')]
        if model:
            client += ['--model', model]
    herdr('agent', 'start', agent_name, '--kind', kind, '--pane', args.pane,
          '--timeout', timeouts['launch_seconds'] * 1000, '--', *client, timeout=timeouts['launch_seconds'])
    started = herdr('agent', 'get', args.pane)['agent']
    if ((started.get('foreground_cwd') or started.get('cwd')) != str(worktree)
            or started.get('agent') != kind or started.get('name') != agent_name
            or started.get('agent_status') in ('blocked', 'unknown')):
        raise Refusal('Client started in an unexpected state/root; inspect its pane before proceeding.')
    print(f'Launched {agent_name}: {started["agent_status"]}, {kind}, {worktree}. Project compilation may still be running.')


if __name__ == '__main__':
    try:
        main()
    except (Refusal, RuntimeError, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        print(f'Worktree setup failed: {error}', file=sys.stderr)
        sys.exit(1)
