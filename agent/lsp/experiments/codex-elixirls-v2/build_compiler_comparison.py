#!/usr/bin/env python3
"""Build private, version-pinned compiler prototypes; never edits installed tools."""
import argparse
import difflib
import json
import os
from pathlib import Path
import subprocess
import shutil


def replace(text, old, new, count=1):
    assert text.count(old) == count, (old[:100], text.count(old), count)
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    upstream = {p.name: p.read_text() for p in (root/'upstream').glob('*.ex')}
    variants = {}

    parallel = upstream['parallel_compiler.ex']
    parallel = replace(parallel,
        '  defp each_file(fun) when is_function(fun, 1), do: fn file, _ -> fun.(file) end\n'
        '  defp each_file(fun) when is_function(fun, 2), do: fun\n',
        '  defp each_file(fun) when is_function(fun, 1), do: fn file, _, _ -> fun.(file) end\n'
        '  defp each_file(fun) when is_function(fun, 2), do: fn file, lexical, _ -> fun.(file, lexical) end\n'
        '  defp each_file(fun) when is_function(fun, 3), do: fun\n')
    parallel = replace(parallel, 'defp each_file(file, lexical, parent)',
                       'defp each_file(file, lexical, source, parent)')
    parallel = replace(parallel, '{:file_ok, self(), ref, file, lexical}',
                       '{:file_ok, self(), ref, file, lexical, source}')
    parallel = replace(parallel, ':elixir_compiler.file(file, &each_file(&1, &2, parent))',
                       'compile_file_contents(file, parent)', 2)
    parallel = replace(parallel, '  defp require_file(file, parent) do', '''  defp compile_file_contents(file, parent) do
    {:ok, source} = :file.read_file(file)

    :elixir_compiler.string(
      :elixir_utils.characters_to_list(source),
      file,
      &each_file(&1, &2, source, parent)
    )
  end

  defp require_file(file, parent) do''')
    parallel = replace(parallel, '{:file_ok, child_pid, ref, file, lexical} ->\n        state.each_file.(file, lexical)',
                       '{:file_ok, child_pid, ref, file, lexical, source} ->\n        state.each_file.(file, lexical, source)')

    compiler = upstream['compiler_elixir.ex']
    compiler = replace(compiler, 'each_file: fn file, lexical ->\n            compiler_call(parent, ref, {:each_file, file, lexical, verbose})',
        'each_file: fn file, lexical, contents ->\n            compiler_call(parent, ref, {:each_file, file, lexical, digest_contents(contents), verbose})')
    compiler = replace(compiler, '{^ref, {:each_file, file, lexical, verbose}}',
                       '{^ref, {:each_file, file, lexical, digest, verbose}}')
    compiler = replace(compiler, 'each_file(file, references, verbose, state, cwd)',
                       'each_file(file, references, digest, verbose, state, cwd)', 2)
    compiler = replace(compiler,
        '        # We preserve the digest if the file is recompiled but not changed\n'
        '        digest: source(source, :digest) || file |> File.read!() |> digest_contents(),',
        '        # Fingerprint the exact buffer parsed by the compiler.\n'
        '        digest: digest,')
    compiler = replace(compiler,
        'source(external: external, size: size, mtime: mtime, digest: digest, modules: modules)',
        'source(external: external, size: size, digest: digest, modules: modules)')
    compiler = replace(compiler, '{last_mtime, last_size} = Map.fetch!(sources_stats, source)',
                       '{_last_mtime, last_size} = Map.fetch!(sources_stats, source)')
    compiler = replace(compiler,
        '                (last_mtime != mtime and\n'
        '                   (missing_beam_file?(dest, modules) or digest_changed?(source, digest)))',
        '                missing_beam_file?(dest, modules) or digest_changed?(source, digest)')
    variants['direct'] = {'parallel_compiler.ex':parallel, 'compiler_elixir.ex':compiler}

    task = replace(upstream['compile_elixir_task.ex'], '    force: :boolean,',
                   '    force: :boolean,\n    force_path: :keep,')
    compiler = upstream['compiler_elixir.ex']
    compiler = replace(compiler,
        '          Map.merge(stale_exports, removed_modules),\n          dest\n',
        '          Map.merge(stale_exports, removed_modules),\n          dest,\n'
        '          MapSet.new(Keyword.get_values(opts, :force_path), &Path.expand/1)\n')
    compiler = replace(compiler, '         stale_exports,\n         dest\n       ) do',
                       '         stale_exports,\n         dest,\n         forced_paths\n       ) do')
    compiler = replace(compiler,
        '            Enum.any?(external, &stale_external?(&1, sources_stats)) or',
        '            MapSet.member?(forced_paths, Path.expand(source)) or\n'
        '                Enum.any?(external, fn {path, _, _} ->\n'
        '                  MapSet.member?(forced_paths, Path.expand(path))\n'
        '                end) or\n'
        '                Enum.any?(external, &stale_external?(&1, sources_stats)) or')
    variants['targeted'] = {'compile_elixir_task.ex':task, 'compiler_elixir.ex':compiler}

    checks = []
    for mode, files in variants.items():
        directory = root/mode
        directory.mkdir(exist_ok=False)
        beam = directory/'beam'; beam.mkdir()
        patches = []
        for name, contents in files.items():
            path = directory/name; path.write_text(contents)
            env = os.environ | {'ERL_FLAGS':'+S 4:4'}
            formatted = subprocess.run(['unbuffer','mix','format',str(path)],cwd=directory,
                                       env=env,text=True,capture_output=True,timeout=30)
            assert formatted.returncode == 0, formatted.stdout+formatted.stderr
            patches.append(''.join(difflib.unified_diff(upstream[name].splitlines(True),
                              path.read_text().splitlines(True),fromfile='a/'+name,tofile='b/'+name)))
            built = subprocess.run(['elixirc','--ignore-module-conflict','--warnings-as-errors',
                                    '-o',str(beam),str(path)],cwd=directory,env=env,
                                   text=True,capture_output=True,timeout=60)
            (directory/(name+'.build.log')).write_text(built.stdout+built.stderr)
            checks.append({'mode':mode,'file':name,'format_exit':formatted.returncode,'build_exit':built.returncode})
            assert built.returncode == 0, built.stdout+built.stderr
        (directory/'candidate.patch').write_text(''.join(patches))
        installed = Path(shutil.which('elixir')).resolve().parent.parent
        shutil.copytree(installed, directory/'toolchain')
        for compiled in beam.glob('*.beam'):
            library = 'mix' if compiled.name.startswith('Elixir.Mix.') else 'elixir'
            destination = directory/'toolchain'/'lib'/library/'ebin'/compiled.name
            destination.chmod(destination.stat().st_mode | 0o200)
            shutil.copy2(compiled, destination)
    (root/'build-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
    print(json.dumps(checks),flush=True)


if __name__ == '__main__':
    main()
