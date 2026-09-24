#!/usr/bin/env python3
"""Compare compiler patches using saved-source ExUnit acceptance assertions."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import hashlib
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--beam', type=Path)
    parser.add_argument('--mode', choices=['baseline', 'direct', 'targeted'], required=True)
    parser.add_argument('--case', choices=['overlap', 'same-stat', 'revert', 'external',
                                          'missing-event', 'ordinary', 'failure-repair',
                                          'create-delete', 'external-preserved', 'external-delete', 'external-repair'], required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    (root / 'lib').mkdir(parents=True, exist_ok=False)
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'dev'}
    if args.beam:
        # Mix resets library paths. A private toolchain copy makes patched
        # modules authoritative without hot-loading or altering installed tools.
        toolchain = args.beam.resolve().parent / 'toolchain'
        env['PATH'] = str(toolchain / 'bin') + os.pathsep + env['PATH']
    commands, writes, controls = [], [], []

    def run(label, *argv, extra=None):
        start = time.monotonic()
        r = subprocess.run(['unbuffer', 'mix', *argv], cwd=root, env=env | (extra or {}),
                           capture_output=True, text=True, timeout=45)
        (root / f'{label}.log').write_text(r.stdout + r.stderr)
        commands.append({'label': label, 'exit': r.returncode, 'ms': round((time.monotonic()-start)*1000),
                         'args': list(argv)})
        return r

    (root / 'mix.exs').write_text('''defmodule Compare.MixProject do
  use Mix.Project
  def project, do: [app: :compare, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / 'lib/caller.ex').write_text('''defmodule CompareCaller do
  @answer CompareTarget.answer()
  def answer, do: @answer
end
''')
    (root / 'lib/unrelated.ex').write_text('''defmodule CompareUnrelated do
  IO.puts("UNRELATED_COMPILED")
  def answer, do: :unrelated
end
''')
    (root / 'acceptance.exs').write_text('''ExUnit.start()

defmodule CompareAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches saved input" do
    assert Atom.to_string(CompareTarget.answer()) == System.fetch_env!("COMPARE_EXPECTED")
  end

  test "compile-time caller matches saved input" do
    assert Atom.to_string(CompareCaller.answer()) == System.fetch_env!("COMPARE_EXPECTED")
  end
end
''')
    (root / 'inspect.exs').write_text('''IO.puts(
  "COMPARE_JSON " <>
    JSON.encode!(%{
      target: CompareTarget.answer(),
      caller: CompareCaller.answer(),
      parallel_compiler: to_string(:code.which(Kernel.ParallelCompiler)),
      mix_compiler: to_string(:code.which(Mix.Compilers.Elixir))
    })
)
''')
    source = root / 'lib/target.ex'
    resource = root / 'lib/value.heex'
    resource.write_text('zz')

    def text(marker):
        return f'''defmodule CompareTarget do
  IO.puts("COMPARE_{marker}_STARTED")
  Process.sleep(1200)
  @doc "{marker} documentation."
  def answer, do: :{marker}
end
'''

    source.write_text(text('zz'))
    if args.case.startswith('external'):
        source.write_text('''defmodule CompareTarget do
  @external_resource Path.expand("value.heex", __DIR__)
  @answer (case File.read(@external_resource) do
    {:ok, value} -> String.to_atom(value)
    {:error, :enoent} -> :missing
  end)
  IO.puts("COMPARE_#{@answer}_STARTED")
  Process.sleep(1200)
  def answer, do: @answer
end
''')
    assert run('format', 'format', 'mix.exs', 'lib/target.ex', 'lib/caller.ex',
               'lib/unrelated.ex', 'acceptance.exs', 'inspect.exs').returncode == 0
    assert run('warmup', 'compile', '--warnings-as-errors').returncode == 0
    changed_path = resource if args.case.startswith('external') else source
    slow_source = source.read_text()

    def write(marker):
        old = changed_path.stat()
        if args.case == 'external-delete' and marker == 'bb':
            changed_path.unlink()
            writes.append({'marker': 'deleted', 'time': time.monotonic()})
            return
        changed_path.write_text(marker if args.case.startswith('external') else slow_source.replace('zz', marker))
        if args.case == 'external-preserved' and marker == 'aa':
            old_second = int(time.time()) - 10
            os.utime(changed_path, (old_second, old_second))
        if args.case in ('same-stat', 'external-preserved') and marker == 'bb':
            os.utime(changed_path, ns=(old.st_atime_ns, old.st_mtime_ns))
        writes.append({'marker': marker, 'time': time.monotonic(),
                       'size': changed_path.stat().st_size, 'mtime_ns': changed_path.stat().st_mtime_ns})

    def compile_args():
        if args.mode == 'targeted' and args.case != 'missing-event':
            return ['compile', '--warnings-as-errors', '--force-path', str(changed_path)]
        return ['compile', '--warnings-as-errors']

    if args.case == 'failure-repair':
        source.write_text(slow_source.replace('zz', 'aa') + '\ninvalid syntax !\n')
        failed = run('failed-compile', *compile_args())
        controls.append({'label': 'compiler rejected invalid input', 'observed': failed.returncode != 0})
        write('bb')
        # Exercise Mix's existing checkpoint recovery, without another hint.
        assert run('followup', 'compile', '--warnings-as-errors').returncode == 0
        expected = 'bb'
    elif args.case == 'create-delete':
        created = root / 'lib/created.ex'
        created.write_text('defmodule CompareCreated do\n  def answer, do: :new\nend\n')
        assert run('created', 'compile', '--warnings-as-errors').returncode == 0
        beam = root / '_build/dev/lib/compare/ebin/Elixir.CompareCreated.beam'
        controls.append({'label': 'created source compiled', 'observed': beam.exists()})
        created.unlink()
        assert run('deleted', 'compile', '--warnings-as-errors').returncode == 0
        controls.append({'label': 'deleted source artifact removed', 'observed': not beam.exists()})
        write('bb')
        assert run('followup', *compile_args()).returncode == 0
        expected = 'bb'
    elif args.case == 'ordinary':
        write('bb')
        assert run('ordinary', *compile_args()).returncode == 0
        expected = 'bb'
    else:
        write('aa')
        # The first event reaches both candidates; targeted needs it even when
        # timestamps are intentionally preserved. Later delivery is tested below.
        first_args = ['compile', '--warnings-as-errors']
        if args.mode == 'targeted':
            first_args += ['--force-path', str(changed_path)]
        first = subprocess.Popen(['unbuffer', 'mix', *first_args], cwd=root, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        lines, changed = [], False
        try:
            for line in first.stdout:
                lines.append(line)
                if 'COMPARE_aa_STARTED' in line:
                    time.sleep(0.4)
                    write('bb')
                    changed = True
            first.wait(timeout=20)
        finally:
            if first.poll() is None:
                first.kill(); first.wait()
        (root / 'overlap.log').write_text(''.join(lines))
        commands.append({'label':'overlap', 'exit':first.returncode, 'args':first_args})
        controls.append({'label': 'overlap', 'observed': changed and first.returncode == 0})
        expected = 'missing' if args.case == 'external-delete' else 'bb'
        if args.case in ('revert', 'external-repair'):
            # The intermediate source was consumed by the compiler; final disk
            # returns to the prior aa revision before its next invocation.
            # Repeat the race with bb compiling and aa saved while it sleeps.
            if changed:
                second = subprocess.Popen(['unbuffer','mix',*compile_args()],cwd=root,env=env,
                                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                lines=[]
                reverted = False
                try:
                    for line in second.stdout:
                        lines.append(line)
                        if 'COMPARE_bb_STARTED' in line:
                            time.sleep(0.4); write('cc' if args.case == 'external-repair' else 'aa')
                            reverted = True
                    second.wait(timeout=20)
                finally:
                    if second.poll() is None: second.kill(); second.wait()
                (root/'revert-overlap.log').write_text(''.join(lines))
                commands.append({'label':'revert-overlap','exit':second.returncode})
                controls.append({'label': 'revert-overlap', 'observed': reverted and second.returncode == 0})
            expected = 'cc' if args.case == 'external-repair' else 'aa'
        time.sleep(2)
        assert run('followup', *compile_args()).returncode == 0

    inspection = run('inspect', 'run', '--no-start', '--no-compile', 'inspect.exs')
    observed = json.loads(next(l.removeprefix('COMPARE_JSON ') for l in inspection.stdout.splitlines()
                               if l.startswith('COMPARE_JSON ')))
    if args.beam:
        for module, filename in [('mix_compiler', 'Elixir.Mix.Compilers.Elixir.beam'),
                                  ('parallel_compiler', 'Elixir.Kernel.ParallelCompiler.beam')]:
            candidate = args.beam.resolve() / filename
            if candidate.exists():
                controls.append({'label': module + ' bytecode matches candidate',
                                 'observed': hashlib.sha256(candidate.read_bytes()).digest() ==
                                 hashlib.sha256(Path(observed[module]).read_bytes()).digest()})
        controls.append({'label': 'patched Mix loaded',
                         'observed': observed['mix_compiler'].startswith(str(toolchain))})
        if args.mode == 'direct':
            controls.append({'label': 'patched parallel compiler loaded',
                             'observed': observed['parallel_compiler'].startswith(str(toolchain))})
    test = run('acceptance', 'run', '--no-start', '--no-compile', 'acceptance.exs',
               extra={'COMPARE_EXPECTED':expected})
    # No event and no new source must become a no-op again.
    settled = run('settled', 'compile', '--warnings-as-errors')
    result = {'mode':args.mode,'case':args.case,'expected':expected,'observed':observed,
              'acceptance_exit':test.returncode,'writes':writes,'commands':commands,'controls':controls,
              'settled_noop':settled.returncode==0 and 'Compiling ' not in settled.stdout,
              'unrelated_recompiled':any('UNRELATED_COMPILED' in (root/f'{name}.log').read_text()
                for name in ['overlap','followup','ordinary','revert-overlap'] if (root/f'{name}.log').exists())}
    result['passed'] = (test.returncode == 0 and result['settled_noop']
                        and not result['unrelated_recompiled'] and all(c['observed'] for c in controls))
    (root/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['mode','case','passed','observed','settled_noop','unrelated_recompiled']}),flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
