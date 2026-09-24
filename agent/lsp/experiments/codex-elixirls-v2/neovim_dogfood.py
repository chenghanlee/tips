#!/usr/bin/env python3
"""Three actual Sol sessions on isolated Tips checkouts, with the reviewed adapter."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from neovim_hook_codex_probe import toml
from neovim_probe import nvim_environment
from probe import alive, descendants

HERE = Path(__file__).resolve().parent
TASKS = {
    'provider': {
        'tests': ['test/tips/provider_config_test.exs', 'test/tips/search_probe_test.exs'],
        'prompt': '''Rename the public Tips.ProviderConfig.mode/0 function to provider_mode/0
across application callers, tests and relevant documentation. Do not keep a compatibility
alias. Preserve real/stub behavior and the existing runtime configuration key :mode.
Use references at an application call site before changing the API. Update existing
acceptance tests first, demonstrate the failure for the new name, then implement the
rename and verify it. Keep this a small complete refactor, with no provider credentials
or external provider requests. Relevant tests include provider_config_test.exs and
search_probe_test.exs; test_helper.exs also uses this API.''',
    },
    'media': {
        'tests': ['test/tips/content/media_schema_test.exs'],
        'prompt': '''Maintain Tips.Content.Media.Target's PostgreSQL bigint ID validation.
Reuse its existing positive_integer/1 validation in canonical_integer/1 instead of
duplicating the ID range rule. Preserve canonical string decoding: no signs, leading
zeroes, trailing junk, zero, negatives or overflow. Extend existing media schema tests
so new_review, edit_tip and edit_review all cover bigint maximum and overflow through
the public cast/dump/load behavior. Retain the existing database persistence coverage.
Run meaningful tests before changing production code and after. This is a behavior-
preserving maintenance refactor; no schema or migration change is needed.''',
    },
    'health': {
        'tests': ['test/tips_web/controllers/health_controller_test.exs'],
        'prompt': '''An intentionally seeded, incomplete private function rename in
lib/tips/health.ex has left the real Tips application unable to compile. Diagnose the
compiler error with the available LSP/compiler feedback and finish the intended rename
from probe/0 to query_database/0. Preserve the one-second deadline, dynamic repository
handling and health endpoint HTTP contract. Reproduce the compile failure before the
minimal repair, then run the health controller integration tests. Do not redesign the
Task supervision or alter unrelated code. The known defect is a dogfood scenario,
not a claim that the current main application is broken.''',
    },
}

COMMON = '''You are one of three explicitly requested Codex Sol dogfood agents, each in
its own worktree. Complete the application task below using the current Tips source.
Read README.md, AGENTS.md and relevant .agents/skills instructions. Do not delegate,
commit, push, modify agent tooling, inspect hook logs/configuration, or read credentials.
Your dependency/build directories, database suffix and ports are isolated and prepared.
The shared PostgreSQL server is already running; do not stop it or reset other databases.

For this experiment, the supplied elixir_neovim MCP lsp tool replaces the Expert tool
named in AGENTS.md. Its operations include hover, definition, references and diagnostics;
uri is an absolute source path and line/character are 1-based. Use it on real task symbols.
Use ordinary file editing tools. Neovim automatically synchronizes disk changes and
compiler feedback arrives through a synchronous hook (at most five seconds per edit).
Do not manually save/open/refresh/index buffers, restart the server, or script around
the integration. If an operation reports indexing, continue useful work and retry later.
If tooling fails, report it accurately and use normal compilation/testing fallbacks.

Use unbuffer mix for Mix commands. Verify formatting, warnings-as-errors compilation,
targeted tests and strict Credo for edited Elixir files. Report existing failures separately.
In your final response summarize the change, checks, and your experience with automatic
compiler feedback: messages actually seen, whether they helped, delays or confusing
responses. Include a feedback receipt if you saw one; do not invent one or read audit logs.
Keep changes narrowly scoped. Your work is an isolated experiment and will not be merged.

Task:
'''


def environment(root, number, name, run_name='sol', port_offset=0):
    values = {
        'PGHOST': '127.0.0.1', 'PGPORT': '5433', 'PGUSER': 'postgres',
        'PGPASSWORD': 'postgres', 'TIPS_DB_SUFFIX': '_lsp_' + run_name + '_' + name,
        'PORT': str(4511 + port_offset + number), 'TIPS_TEST_PORT': str(4611 + port_offset + number),
        'TIPS_PROVIDER_ENV_FILE': str(root / 'tmp/no-providers.env'),
        'TIPS_REAL_PROVIDERS': '0', 'TIPS_BROWSER': '0', 'ERL_FLAGS': '+S 4:4',
        'MIX_ENV': 'dev', 'MIX_TEST_PARTITION': '',
    }
    for key in ('OPENROUTER_API_KEY CLOUDFLARE_ACCOUNT_ID R2_BUCKET R2_ENDPOINT '
                'R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL '
                'CLOUDFLARE_STREAM_API_TOKEN CLOUDFLARE_STREAM_CUSTOMER_CODE '
                'CLOUDFLARE_STREAM_SIGNING_KEY').split():
        values[key] = ''
    return values


def baseline(name, root, out, values):
    results = []
    commands = [(['unbuffer', 'mix', 'compile', '--warnings-as-errors'], 'dev'),
                (['unbuffer', 'mix', 'test', *TASKS[name]['tests']], 'test')]
    for index, (command, mix_env) in enumerate(commands):
        started = time.monotonic()
        with (out / f'baseline-{index}.log').open('w') as log:
            proc = subprocess.run(command, cwd=root, env=os.environ | values | {'MIX_ENV': mix_env},
                                  stdout=log, stderr=subprocess.STDOUT, timeout=600)
        results.append({'command': command, 'exit_code': proc.returncode,
                        'seconds': round(time.monotonic() - started, 3)})
        print(json.dumps({'worker': name, 'baseline': results[-1]}), flush=True)
        if proc.returncode:
            break
    (out / 'baseline.json').write_text(json.dumps(results, indent=2) + '\n')
    return all(result['exit_code'] == 0 for result in results)


def run_agent(name, root, out, values, vendor, bundle=None):
    if bundle:
        import importlib.util
        spec = importlib.util.spec_from_file_location('installed_bundle', bundle / 'bundle.py')
        installed = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installed)
        installed.verify()
        state = out / 'session'
        env = json.loads(installed.prepare(root, state).read_text())
    else:
        env = nvim_environment(vendor, out, 'codex', sync_reads=True, feedback=True, automatic=True)
    # ElixirLS uses dev, while a bare `mix test` must be allowed to select test itself.
    values = {key: value for key, value in values.items() if key != 'MIX_ENV'}
    env.update(values)
    environment_file = out / 'environment.json'
    environment_file.write_text(json.dumps(env, indent=2) + '\n')
    hook = shlex.join([sys.executable, str(HERE / 'neovim_hook.py'), '--vendor', str(vendor),
                      '--workspace', str(root), '--registry', env['VV_MCP_REGISTRY'],
                      '--budget-ms', '5000', '--audit', str(out / 'hook-audit.jsonl')])
    config = {
        'mcp_servers.elixir_neovim.command': sys.executable,
        'mcp_servers.elixir_neovim.args': [str(HERE / 'neovim_launcher.py'), '--vendor', str(vendor),
                                        '--workspace', str(root), '--environment', str(environment_file)],
        'mcp_servers.elixir_neovim.cwd': str(root),
        'mcp_servers.elixir_neovim.enabled_tools': ['lsp'],
        'mcp_servers.elixir_neovim.required': True,
        'sandbox_workspace_write.network_access': True,
        'shell_environment_policy.set': values,
        'hooks.PostToolUse': [{'matcher': '^(apply_patch|Bash)$', 'hooks': [
            {'type': 'command', 'command': hook, 'timeout': 6,
             'statusMessage': 'Reading ElixirLS compiler feedback'}]}],
        'hooks.Stop': [{'hooks': [
            {'type': 'command', 'command': hook, 'timeout': 6,
             'statusMessage': 'Checking pending ElixirLS feedback'}]}],
    }
    if bundle:
        hook = shlex.join([sys.executable, str(bundle / 'bundle.py'), 'hook',
                          '--workspace', str(root), '--state', str(state),
                          '--budget-ms', '5000', '--audit', str(out / 'hook-audit.jsonl')])
        config['mcp_servers.elixir_neovim.args'] = [str(bundle / 'bundle.py'), 'serve',
                                                   '--workspace', str(root), '--state', str(state)]
        for groups in (config['hooks.PostToolUse'], config['hooks.Stop']):
            for group in groups:
                for entry in group['hooks']:
                    entry['command'] = hook
    prompt = COMMON + TASKS[name]['prompt']
    (out / 'prompt.md').write_text(prompt + '\n')
    command = ['codex', 'exec', '--ignore-user-config', '--ephemeral', '--json',
               '--dangerously-bypass-hook-trust', '--approve-for-me',
               '-m', 'gpt-6-sol', '-C', str(root), '-o', str(out / 'final.md')]
    for key, value in config.items():
        command.extend(['-c', key + '=' + toml(value)])
    command.append('-')
    (out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    owned, started = {}, time.monotonic()
    proc = None
    try:
        with (out / 'events.jsonl').open('w') as stdout, (out / 'stderr.log').open('w') as stderr:
            proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
                                    env=os.environ | values, start_new_session=True, text=True)
            proc.stdin.write(prompt)
            proc.stdin.close()
            print(json.dumps({'worker': name, 'started_pid': proc.pid}), flush=True)
            deadline = time.monotonic() + 1500
            while proc.poll() is None and time.monotonic() < deadline:
                owned.update(descendants(proc.pid))
                time.sleep(0.5)
            if proc.poll() is None:
                raise TimeoutError(f'{name}: Codex exceeded 25 minutes')
        deadline = time.monotonic() + 10
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.25)
        result = {'worker': name, 'model': 'gpt-6-sol', 'exit_code': proc.returncode,
                  'seconds': round(time.monotonic() - started, 3), 'owned': owned,
                  'remaining_before_cleanup': alive(owned)}
        (out / 'process-results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'owned'}), flush=True)
        return result
    finally:
        if proc and proc.poll() is None:
            owned.update(descendants(proc.pid))
        for pid in alive(owned):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.25)
        for pid in alive(owned):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['baseline', 'run'])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--worktree-prefix', default='/private/tmp/tips-lsp-sol-')
    parser.add_argument('--run-name', default='sol')
    parser.add_argument('--port-offset', type=int, default=0)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    jobs = []
    with ThreadPoolExecutor(max_workers=3) as executor:
        for number, name in enumerate(TASKS):
            root = Path(args.worktree_prefix + name)
            out = output / name
            out.mkdir(exist_ok=True)
            values = environment(root, number, name, args.run_name, args.port_offset)
            if args.phase == 'baseline':
                (out / 'application-environment.json').write_text(json.dumps(values, indent=2) + '\n')
                jobs.append(executor.submit(baseline, name, root, out, values))
            else:
                baseline_results = json.loads((out / 'baseline.json').read_text())
                assert len(baseline_results) == 2 and all(r['exit_code'] == 0 for r in baseline_results)
                jobs.append(executor.submit(run_agent, name, root, out, values, args.vendor.resolve()))
        results = [job.result() for job in jobs]
    if args.phase == 'baseline':
        assert all(results), 'Baseline failures; inspect logs before launching agents'
    else:
        assert all(r['exit_code'] == 0 and not r['remaining_before_cleanup'] for r in results), \
            'Agent or cleanup failures; inspect process-results.json'


if __name__ == '__main__':
    main()
