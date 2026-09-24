#!/usr/bin/env python3
"""Own one headless Neovim and the published vv-mcp stdio server per session.

MCP bytes pass directly to vv-mcp; this launcher implements no protocol tools.
Eager startup lets post-edit hooks work without a model first calling an LSP tool.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--environment', type=Path, required=True)
    args = parser.parse_args()
    vendor, root = args.vendor.resolve(), args.workspace.resolve()
    env = os.environ | json.loads(args.environment.read_text())
    fd, socket = tempfile.mkstemp(prefix='elixir-nvim-', suffix='.sock')
    os.close(fd)
    os.unlink(socket)
    nvim, bridge = None, None
    owner_path = Path(env['VV_MCP_REGISTRY']).parent / 'owner.json'
    published_owner = False

    def terminate(*_):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        with args.environment.with_suffix('.nvim.log').open('w') as log:
            nvim = subprocess.Popen([str(vendor / 'nvim-macos-arm64/bin/nvim'), '--embed', '--headless',
                                     '--listen', socket, str(root / 'mix.exs')], cwd=root, env=env,
                                    stdin=subprocess.PIPE, stdout=log, stderr=log, start_new_session=True)
            # Wait for this instance's registry entry, not compiler readiness.
            deadline = time.monotonic() + 5
            entry_path = Path(env['VV_MCP_REGISTRY']) / f'{nvim.pid}.json'
            while True:
                if nvim.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Owned Neovim failed to register within five seconds')
                try:
                    entry = json.loads(entry_path.read_text())
                    if (entry['pid'] == nvim.pid and entry['socket'] == socket
                            and entry['kind'] == 'interactive'):
                        break
                except (OSError, ValueError, KeyError):
                    pass  # Registration may not exist yet.
                time.sleep(0.02)
            owner_path.write_text(json.dumps(entry) + '\n')
            published_owner = True
            args.environment.with_suffix('.startup.json').write_text(json.dumps({
                'status': 'registered', 'instanceId': entry['instanceId'],
                'message': 'Compiler readiness is reported by hooks and MCP tools.'}) + '\n')
            # The bound server never falls back to a managed replacement.
            bridge = subprocess.Popen([str(vendor / 'vv-mcp'), '--instance-id',
                                       entry['instanceId']], cwd=root, env=env, stdin=subprocess.PIPE)
            def forward_stdin():
                try:
                    while data := os.read(sys.stdin.fileno(), 65536):
                        bridge.stdin.write(data)
                        bridge.stdin.flush()
                except (BrokenPipeError, OSError):
                    pass
                finally:
                    bridge.stdin.close()
            # A private pipe gives vv-mcp EOF even if this launcher is killed.
            # Forward raw bytes; vv-mcp remains the only MCP implementation.
            threading.Thread(target=forward_stdin, daemon=True).start()
            while bridge.poll() is None:
                if nvim.poll() is not None:
                    raise RuntimeError('Owned Neovim exited; this MCP session is unavailable')
                time.sleep(0.05)
            raise SystemExit(bridge.returncode)
    finally:
        if bridge is not None and bridge.poll() is None:
            bridge.terminate()
            try:
                bridge.wait(timeout=3)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait()
        if nvim is not None:
            # No RPC here: cleanup must work when the peer cannot answer.
            nvim.stdin.close()
            try:
                os.killpg(nvim.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                nvim.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # A compiler can outlive the editor's graceful exit. Both share our
            # private group (ElixirLS detached=false), so reap the remainder too.
            try:
                os.killpg(nvim.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            nvim.wait(timeout=2)
        if published_owner:
            owner_path.unlink(missing_ok=True)
        Path(socket).unlink(missing_ok=True)


if __name__ == '__main__':
    main()
