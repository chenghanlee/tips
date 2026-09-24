#!/usr/bin/env python3
"""Real Tips workloads against one installed bundle, in three actual Sol sessions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess

import neovim_dogfood as dogfood

dogfood.TASKS['repo'] = {
    'tests': ['test/tips/repo_timeout_test.exs'],
    'prompt': '''Investigate GitHub issue #200 locally: DBConnection checkout retries can
extend Tips.Repo's effective request deadline. Add a focused regression/integration
test using an isolated, deliberately constrained connection pool to distinguish the
default checkout-retry behavior from checkout_retries: 0. Use the real installed
DBConnection/Postgrex/Ecto stack and explain what the measured result does and does
not prove about production policy. Keep existing maintenance-query deadline tests
passing. If a deterministic reproduction needs a different bounded test setup, use
the smallest viable one and document it. Do not change global production pool policy
or require external services beyond the provided PostgreSQL. Write a short evidence
note in tmp/issue-200-findings.md with the proposed next decision. This is investigation
and regression coverage, not authorization to close #200.''',
}
del dogfood.TASKS['health']
dogfood.COMMON = dogfood.COMMON.replace(
    'Read README.md, AGENTS.md and relevant .agents/skills instructions.',
    'Read README.md and AGENTS.md. The Elixir skills are installed at '
    '/Users/chenghanlee/.claude/plugins/marketplaces/elixir-agent-tools/plugins/elixir-dev/skills/; '
    'read elixir/SKILL.md and relevant ecto/otp skills there.')
dogfood.COMMON += '''
Release-gate prelude (explicitly authorized fault injection in your isolated checkout):
After reading the required project instructions and skills, make your FIRST edit a
temporary compiler error in the task module below: add a public function
def __lsp_gate_probe__, do: missing_release_gate_function()
inside that module using apply_patch. Do this before broad code exploration so it
overlaps the cold ElixirLS compilation if possible. Query document_symbols for that
file and continue useful task exploration/tests while initial compilation runs. Read
the automatic feedback. Once the compiler error is reported, remove only the temporary
function with apply_patch. Confirm that automatic feedback recovers and diagnostics
clear. Never leave this function in the final patch. This seeded fault is a tooling
test, not an application bug discovered by you. Do not add compile sleeps or manually
refresh/restart/save Neovim. Report pending/error/repaired feedback and any receipt
you actually see. If feedback fails, report it and complete the task using normal tools.

Actual application workload and prelude module:
'''
MODULES = {'provider': 'lib/tips/provider_config.ex',
           'media': 'lib/tips/content/media/target.ex', 'repo': 'lib/tips/repo.ex'}
for name, task in dogfood.TASKS.items():
    task['prompt'] = f"Prelude module: {MODULES[name]}\n\n" + task['prompt']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['baseline', 'run'])
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    jobs = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        for index, name in enumerate(dogfood.TASKS):
            root = Path('/private/tmp/tips-lsp-release-' + name)
            out = output / name
            out.mkdir(exist_ok=True)
            values = dogfood.environment(root, index, name, 'release', 60)
            if args.phase == 'baseline':
                (out / 'application-environment.json').write_text(json.dumps(values, indent=2) + '\n')
                jobs.append(pool.submit(dogfood.baseline, name, root, out, values))
            else:
                baseline = json.loads((out / 'baseline.json').read_text())
                assert len(baseline) == 2 and all(r['exit_code'] == 0 for r in baseline)
                values['PATH'] = str(bundle / 'toolchain/bin') + os.pathsep + os.environ['PATH']
                jobs.append(pool.submit(dogfood.run_agent, name, root, out, values,
                                        bundle / 'vendor', bundle))
        results = [job.result() for job in jobs]
    (output / (args.phase + '-results.json')).write_text(json.dumps(results, indent=2) + '\n')
    if args.phase == 'baseline':
        assert all(results), 'Baseline failed; inspect evidence before launching agents'
    else:
        assert all(r['exit_code'] == 0 and not r['remaining_before_cleanup'] for r in results)


if __name__ == '__main__':
    main()
