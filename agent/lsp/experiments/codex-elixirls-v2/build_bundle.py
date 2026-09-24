#!/usr/bin/env python3
"""Build the pinned stack from source archives; installed output is relocatable.

Build prerequisites: macOS arm64, Elixir 1.20.4 / OTP 29.1, Python 3.14.3,
Rust 1.97.0, curl, git, patch and unbuffer. No prior experiment build is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    root, cache = args.destination.resolve(), args.cache.resolve()
    if root.exists():
        parser.error('Destination already exists; use a fresh destination')
    if (platform.system(), platform.machine(), platform.python_version()) != ('Darwin', 'arm64', '3.14.3'):
        parser.error('Requires macOS arm64 and Python 3.14.3')
    lock = json.loads((HERE / 'bundle-lock.json').read_text())
    root.mkdir(parents=True)
    cache.mkdir(parents=True, exist_ok=True)
    log = (root / 'build.log').open('w')
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'prod',
                       'MIX_HOME': str(root / 'mix-home'), 'HEX_HOME': str(root / 'hex-home')}

    def run(command, cwd=root):
        print(' '.join(map(str, command)), flush=True)
        result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                                stdout=log, stderr=subprocess.STDOUT)
        log.flush()
        if result.returncode:
            raise RuntimeError(f'Command failed ({result.returncode}); see {root / "build.log"}')

    def fetch(name):
        item = lock['downloads'][name]
        path = cache / name
        if not path.exists():
            run(['curl', '-fL', '--retry', '3', item['url'], '-o', path])
        if sha(path) != item['sha256']:
            raise RuntimeError('Download checksum mismatch: ' + name)
        return path

    def extract(name, dest):
        with tarfile.open(fetch(name)) as archive:
            members = archive.getmembers()
            top = members[0].name.split('/')[0]
            staging = root / ('extract-' + name)
            archive.extractall(staging, filter='data')
            shutil.move(staging / top, dest)
            staging.rmdir()

    rust = subprocess.check_output(['rustc', '--version'], text=True)
    if not rust.startswith('rustc 1.97.0 '):
        raise RuntimeError('Requires Rust 1.97.0')
    shutil.copytree(Path(shutil.which('elixir')).resolve().parent.parent, root / 'toolchain')
    for beam in (root / 'toolchain/lib/mix/ebin').glob('*.beam'):
        beam.chmod(beam.stat().st_mode | 0o200)
    env['PATH'] = str(root / 'toolchain/bin') + os.pathsep + env['PATH']
    version = subprocess.check_output(['elixir', '-e',
        'IO.write(System.version() <> "/" <> String.trim(File.read!(Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]))))'],
        env=env, text=True)
    if version != '1.20.4/29.1':
        raise RuntimeError('Requires Elixir 1.20.4/OTP 29.1; found ' + version)
    sources = root / 'sources'
    sources.mkdir()
    for name in ('compiler_elixir.ex', 'compile_elixir_task.ex'):
        shutil.copy2(fetch(name), sources / name)
    run(['patch', '-p1', '-i', HERE / 'mix-targeted-invalidation.patch'], sources)
    for name in ('compiler_elixir.ex', 'compile_elixir_task.ex'):
        run(['elixirc', '--ignore-module-conflict', '--warnings-as-errors', '-o',
             root / 'toolchain/lib/mix/ebin', sources / name])
    extract('hex-source.tar.gz', sources / 'hex')
    run(['unbuffer', 'mix', 'archive.build'], sources / 'hex')
    run(['unbuffer', 'mix', 'archive.install', sources / 'hex/hex-2.5.1.ez', '--force'])
    extract('elixirls.tar.gz', sources / 'elixirls')
    run(['patch', '-p1', '-i', HERE / 'elixirls-targeted-invalidation.patch'], sources / 'elixirls')
    run(['unbuffer', 'mix', 'deps.get', '--check-locked'], sources / 'elixirls')
    run(['unbuffer', 'mix', 'compile'], sources / 'elixirls')
    (root / 'server/lib').mkdir(parents=True)
    for app in (sources / 'elixirls/_build/shared/lib').iterdir():
        if (app / 'ebin').is_dir():
            for part in ('ebin', 'priv'):
                if (app / part).exists():
                    shutil.copytree(app / part, root / 'server/lib' / app.name / part)
    vendor = root / 'vendor'
    vendor.mkdir()
    extract('nvim.tar.gz', vendor / 'nvim-macos-arm64')
    extract('vv-mcp.tar.gz', vendor / 'beixiyo-vv-mcp.nvim')
    extract('vv-utils.tar.gz', vendor / 'beixiyo-vv-utils.nvim')
    for patch in ('vv-mcp-feedback.patch', 'vv-mcp-owner.patch'):
        run(['patch', '-p1', '-i', HERE / patch], vendor / 'beixiyo-vv-mcp.nvim')
    run(['cargo', 'build', '--release', '--locked', '-p', 'vv-mcp'], vendor / 'beixiyo-vv-mcp.nvim')
    shutil.copy2(vendor / 'beixiyo-vv-mcp.nvim/target/release/vv-mcp', vendor / 'vv-mcp')
    wheels = [fetch(name) for name in lock['downloads'] if name.endswith('.whl')]
    run([sys.executable, '-m', 'pip', 'install', '--no-deps', '--no-index', '--target', vendor / 'python', *wheels])
    (root / 'adapter').mkdir()
    for name in ('neovim_init.lua', 'neovim_sync.lua', 'neovim_feedback.lua', 'neovim_launcher.py', 'neovim_hook.py'):
        shutil.copy2(HERE / name, root / 'adapter' / name)
    shutil.copy2(HERE / 'bundle.py', root / 'bundle.py')
    # /usr/bin/env follows the explicit Python prerequisite, not a build-directory path.
    launcher = root / 'elixir-ls'
    launcher.write_text('#!/bin/sh\nexec python3 "$(dirname "$0")/bundle.py" server\n')
    launcher.chmod(0o755)
    for name in ('bundle-lock.json', 'mix-targeted-invalidation.patch', 'elixirls-targeted-invalidation.patch', 'vv-mcp-feedback.patch', 'vv-mcp-owner.patch'):
        shutil.copy2(HERE / name, root / name)
    # Keep provenance sources but discard build-only Rust output and dependency Git data.
    shutil.rmtree(vendor / 'beixiyo-vv-mcp.nvim/target')
    critical = [root / 'bundle.py', launcher, vendor / 'vv-mcp', vendor / 'nvim-macos-arm64/bin/nvim']
    for directory, pattern in [('adapter', '*'), ('toolchain/lib/mix/ebin', '*.beam'),
                               ('server/lib', '**/*.beam'), ('server/lib', '**/*.app'),
                               ('vendor/beixiyo-vv-mcp.nvim/lua', '**/*.lua'),
                               ('vendor/beixiyo-vv-utils.nvim/lua', '**/*.lua')]:
        critical += [p for p in (root / directory).glob(pattern) if p.is_file()]
    manifest = {'format': 1, 'elixir_otp': version, 'python': platform.python_version(),
                'rust_build': rust.strip(), 'lock': lock,
                'patches': {p.name: sha(p) for p in root.glob('*.patch')},
                'files': {str(p.relative_to(root)): sha(p) for p in critical}}
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    run([sys.executable, root / 'bundle.py', 'doctor'])
    print('Built and verified ' + str(root), flush=True)


if __name__ == '__main__':
    main()
