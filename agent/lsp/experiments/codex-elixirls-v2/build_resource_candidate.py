#!/usr/bin/env python3
"""Investigate content brackets for known resources; ABA is a required test."""
import argparse
import difflib
import os
from pathlib import Path
import shutil
import subprocess
from build_compiler_comparison import replace


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    compiler = (args.base / 'compiler_elixir.ex').read_text()
    compiler = replace(compiler, '          consolidation: consolidation\n        }',
        '          consolidation: consolidation,\n          resource_inputs: resource_inputs(all_sources)\n        }')
    compiler = replace(compiler, '    external = process_external_resources(external, cwd)',
        '    external = process_external_resources(external, cwd, state.resource_inputs)')
    start = compiler.index('  defp stale_external?(')
    end = compiler.index('  defp mtimes_and_sizes', start)
    compiler = compiler[:start] + '''  # An explicit provisional tag is distinct from an absent resource (nil).
  defp stale_external?({_external, _stat, :unverified_resource}, _stats), do: true

  defp stale_external?({external, _stat, digest}, _stats) do
    resource_digest(external) != digest
  end

  defp resource_digest(file) do
    case File.read(file) do
      {:ok, bytes} -> digest_contents(bytes)
      {:error, :enoent} -> nil
      {:error, _reason} -> :unverified_resource
    end
  end

  defp resource_inputs(sources) do
    for {_path, source(external: external)} <- sources,
        {path, _, _} <- external,
        into: %{},
        do: {path, resource_digest(path)}
  end

''' + compiler[end:]
    start = compiler.index('  defp process_external_resources(')
    end = compiler.index('\n  end', start) + len('\n  end')
    compiler = compiler[:start] + '''  defp process_external_resources(external, cwd, inputs) do
    for file <- external do
      path = Path.relative_to(file, cwd)
      after_digest = resource_digest(file)

      digest =
        case Map.fetch(inputs, path) do
          {:ok, ^after_digest} -> after_digest
          _ -> :unverified_resource
        end

      {path, Mix.Utils.last_modified_and_size(file), digest}
    end
  end''' + compiler[end:]
    path = root / 'compiler_elixir.ex'
    path.write_text(compiler)
    env = os.environ | {'ERL_FLAGS': '+S 4:4'}
    for command in [['unbuffer', 'mix', 'format', str(path)],
            ['elixirc', '--ignore-module-conflict', '--warnings-as-errors', '-o', str(root / 'beam'), str(path)]]:
        p = subprocess.run(command, env=env, cwd=root, text=True, capture_output=True, timeout=60)
        assert p.returncode == 0, p.stdout + p.stderr
    shutil.copy2(args.base / 'parallel_compiler.ex', root / 'parallel_compiler.ex')
    shutil.copy2(args.base / 'beam/Elixir.Kernel.ParallelCompiler.beam', root / 'beam')
    shutil.copytree(args.base / 'toolchain', root / 'toolchain')
    beam = root / 'beam/Elixir.Mix.Compilers.Elixir.beam'
    dest = root / 'toolchain/lib/mix/ebin' / beam.name
    dest.chmod(dest.stat().st_mode | 0o200)
    shutil.copy2(beam, dest)
    (root / 'resource-only.patch').write_text(''.join(difflib.unified_diff(
        (args.base / 'compiler_elixir.ex').read_text().splitlines(True), path.read_text().splitlines(True),
        fromfile='a/compiler_elixir.ex', tofile='b/compiler_elixir.ex')))
    print(root, flush=True)


if __name__ == '__main__':
    main()
