#!/usr/bin/env python3
"""Installed stack entry point. No experiment or download directory is consulted."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def verify():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('This bundle supports macOS arm64 only')
    if platform.python_version() != manifest['python']:
        raise RuntimeError('Python version differs from the bundle: ' + manifest['python'])
    for name, expected in manifest['files'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Bundle integrity mismatch: ' + name)
    version = subprocess.check_output(
        [str(ROOT / 'toolchain/bin/elixir'), '-e',
         'IO.write(System.version() <> "/" <> String.trim(File.read!(Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]))))'],
        env=os.environ | {'ERL_FLAGS': '+S 2:2'}, text=True)
    if version != manifest['elixir_otp']:
        raise RuntimeError('Elixir/OTP mismatch: ' + version)
    return manifest


def prepare(workspace, state):
    workspace, state = workspace.resolve(strict=True), state.resolve()
    if not (workspace / 'mix.exs').is_file():
        raise ValueError('Workspace must contain mix.exs')
    config = state / 'config/nvim'
    (config / 'lua').mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy2(ROOT / 'adapter/neovim_init.lua', config / 'init.lua')
    for name in ('neovim_sync.lua', 'neovim_feedback.lua'):
        shutil.copy2(ROOT / 'adapter' / name, config / 'lua' / name)
    env = {f'XDG_{kind.upper()}_HOME': str(state / kind)
           for kind in ('config', 'data', 'state', 'cache')}
    env.update({
        'PATH': str(ROOT / 'toolchain/bin') + os.pathsep + str(ROOT / 'vendor/nvim-macos-arm64/bin') + os.pathsep + os.environ['PATH'],
        'NVIM_LOG_FILE': str(state / 'nvim.log'),
        'VV_MCP_REGISTRY': str(state / 'registry'),
        'V2_VV_PLUGIN': str(ROOT / 'vendor/beixiyo-vv-mcp.nvim'),
        'V2_VV_UTILS': str(ROOT / 'vendor/beixiyo-vv-utils.nvim'),
        'V2_VV_BINARY': str(ROOT / 'vendor/vv-mcp'),
        'V2_ELIXIR_LS': str(ROOT / 'elixir-ls'),
        'VV_MCP_MANAGED_IDLE_TIMEOUT_MS': '300000',
        'V2_SYNC_READS': '1', 'V2_FEEDBACK': '1', 'V2_AUTOMATIC': '1',
    })
    path = state / 'environment.json'
    path.write_text(json.dumps(env, indent=2) + '\n')
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['doctor', 'prepare', 'serve', 'hook', 'server'])
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--state', type=Path)
    args, extra = parser.parse_known_args()
    if args.mode == 'doctor':
        print(json.dumps(verify(), indent=2))
    elif args.mode == 'server':
        # Upstream main owns protocol, logging, Mix and application startup.
        # All library directories are private, precompiled and relocated together.
        env = os.environ | {'MIX_HOME': str(ROOT / 'mix-home'), 'ELS_MODE': 'language_server'}
        command = [str(ROOT / 'toolchain/bin/elixir')]
        for ebin in sorted((ROOT / 'server/lib').glob('*/ebin')):
            command += ['-pa', str(ebin)]
        command += ['-e', 'Application.put_env(:elixir, :ansi_enabled, false); ElixirLS.LanguageServer.main()']
        os.execve(command[0], command, env)
    else:
        if not args.workspace or not args.state:
            parser.error('--workspace and --state are required')
        if args.mode == 'prepare':
            verify()
            print(prepare(args.workspace, args.state))
        elif args.mode == 'serve':
            verify()
            path = prepare(args.workspace, args.state)
            os.execv(sys.executable, [sys.executable, str(ROOT / 'adapter/neovim_launcher.py'),
                     '--vendor', str(ROOT / 'vendor'), '--workspace', str(args.workspace.resolve()),
                     '--environment', str(path)])
        else:
            os.execv(sys.executable, [sys.executable, str(ROOT / 'adapter/neovim_hook.py'),
                     '--vendor', str(ROOT / 'vendor'), '--workspace', str(args.workspace.resolve()),
                     '--registry', str(args.state.resolve() / 'registry'), *extra])


if __name__ == '__main__':
    main()
