#!/usr/bin/env python3
"""Build only the existing targeted Mix patch in a private Elixir tree."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request

HERE = Path(__file__).resolve().parent
PREVIOUS = HERE.parent / 'codex-elixirls-v2'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--destination', type=Path, required=True)
    p.add_argument('--cache', type=Path, required=True)
    args = p.parse_args()
    root = args.destination.resolve()
    cache = args.cache.resolve()
    root.mkdir(parents=True, exist_ok=False)
    cache.mkdir(parents=True, exist_ok=True)
    env = os.environ | {'ERL_FLAGS': '+S 4:4'}
    version = subprocess.check_output(['elixir', '-e',
        'IO.write(System.version() <> "/" <> String.trim(File.read!(Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]))))'],
        env=env, text=True)
    if version != '1.20.4/29.1':
        raise RuntimeError('This prototype requires Elixir 1.20.4 / OTP 29.1')
    source_root = Path(shutil.which('elixir')).resolve().parent.parent
    shutil.copytree(source_root, root / 'toolchain')
    sources = root / 'sources'
    sources.mkdir()
    lock = json.loads((PREVIOUS / 'bundle-lock.json').read_text())['downloads']
    inputs = {}
    for name in ('compiler_elixir.ex', 'compile_elixir_task.ex'):
        path = cache / name
        if not path.exists():
            path.write_bytes(urllib.request.urlopen(lock[name]['url'], timeout=30).read())
        if sha(path) != lock[name]['sha256']:
            raise RuntimeError('Source hash mismatch: ' + name)
        inputs[name] = sha(path)
        shutil.copy2(path, sources / name)
    patch = PREVIOUS / 'mix-targeted-invalidation.patch'
    shutil.copy2(patch, root / patch.name)
    log_path = root / 'build.log'
    with log_path.open('w') as log:
        def run(command, cwd=sources):
            result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                stdout=log, stderr=subprocess.STDOUT, timeout=60)
            log.flush()
            if result.returncode:
                raise RuntimeError('Build failed: ' + str(log_path))
        run(['patch', '-p1', '-i', patch])
        ebin = root / 'toolchain/lib/mix/ebin'
        names = ['Elixir.Mix.Compilers.Elixir.beam', 'Elixir.Mix.Tasks.Compile.Elixir.beam']
        for name in names:
            (ebin / name).chmod((ebin / name).stat().st_mode | 0o200)
        run(['unbuffer', 'mix', 'format', '--check-formatted', *inputs])
        for name in inputs:
            run(['elixirc', '--ignore-module-conflict', '--warnings-as-errors', '-o', ebin, sources / name])
    manifest = {'elixir_otp': version, 'source_sha256': inputs, 'patch_sha256': sha(patch),
                'files': {str((ebin / n).relative_to(root / 'toolchain')): sha(ebin / n) for n in names}}
    (root / 'toolchain/foreground-mix-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'toolchain': str(root / 'toolchain'), 'manifest': manifest}, indent=2))


if __name__ == '__main__':
    main()
