"""Real daemon startup and saved configuration, using authentic Elixir sources."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

DX = Path(__file__).resolve().parents[1] / 'dx.py'
BINARY = os.environ.get('DEXTER_BINARY')
STDLIB = os.environ.get('DEXTER_ELIXIR_LIB_ROOT')


@unittest.skipUnless(BINARY and STDLIB, 'set DEXTER_BINARY and DEXTER_ELIXIR_LIB_ROOT')
class StandardLibrary(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dx-stdlib-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(subprocess.run, [BINARY, '-C', str(self.root), 'stop'], capture_output=True)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / 'mix.exs').write_text('defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: "0.1.0"]\nend\n')
        (self.root / 'sample.ex').write_text('defmodule Sample do\n  def run, do: Enum.map([1], & &1)\nend\n')
        self.env = dict(os.environ)
        self.env['DEXTER_DAEMON_IDLE_TIMEOUT'] = '5s'
        self.env.pop('DEXTER_ELIXIR_LIB_ROOT', None)

    def invoke(self, op, params=None, stdlib=None):
        env = dict(self.env)
        if stdlib is not None:
            env['DEXTER_ELIXIR_LIB_ROOT'] = str(stdlib)
        p = subprocess.run([sys.executable, str(DX), '--json', '--binary', BINARY,
                            '--root', str(self.root), op], input=json.dumps(params or {}),
                           env=env, capture_output=True, text=True, timeout=90)
        self.assertTrue(p.stdout, p.stderr)
        return p.returncode, json.loads(p.stdout)

    def test_saved_config_repairs_legacy_daemon_and_survives_restart(self):
        # A daemon already running without the new configuration must be restarted.
        subprocess.run([BINARY, 'init', str(self.root)], env=self.env, capture_output=True, check=True)
        subprocess.run([BINARY, '-C', str(self.root), 'reindex'], env=self.env, capture_output=True, check=True)
        code, report = self.invoke('start', stdlib=STDLIB)
        self.assertEqual(code, 0, report)
        self.assertEqual(report['stdlib']['status'], 'configured')
        self.assertIn('restart', report)
        code, again = self.invoke('start')
        self.assertEqual(code, 0, again)
        self.assertNotIn('restart', again)
        for restarted in (False, True):
            if restarted:
                subprocess.run([BINARY, '-C', str(self.root), 'stop'], capture_output=True, check=True)
            # New harness process: no env override. Both lookups need real sources.
            code, hover = self.invoke('hover', {'file': 'sample.ex', 'line': 2, 'column': 22})
            self.assertEqual(code, 0, hover)
            self.assertIn('enumerable', json.dumps(hover['result']).lower())
            code, definition = self.invoke('definition', {'file': 'sample.ex', 'line': 2, 'column': 22})
            self.assertEqual(code, 0, definition)
            self.assertIn((Path(STDLIB).resolve() / 'elixir/lib/enum.ex').as_uri(), json.dumps(definition['result']))
            self.assertEqual(definition['stdlib']['root'], str(Path(STDLIB).resolve()))

    def test_missing_or_sourceless_config_is_rejected_before_indexing(self):
        for path in (None, self.root):
            code, report = self.invoke('start', stdlib=path)
            self.assertNotEqual(code, 0, report)
            self.assertEqual(report['error']['kind'], 'stdlib')
            self.assertFalse((self.root / '.dexter/dexter.db').exists())

    def test_version_mismatch_is_rejected_before_indexing(self):
        fake = self.root / 'wrong-version'
        (fake / 'lib/elixir/lib').mkdir(parents=True)
        (fake / 'lib/elixir/lib/enum.ex').write_text('defmodule Enum do\nend\n')
        (fake / 'VERSION').write_text('0.0.0')
        code, report = self.invoke('start', stdlib=fake / 'lib')
        self.assertNotEqual(code, 0, report)
        self.assertEqual(report['error']['kind'], 'stdlib')
        self.assertIn('version', str(report['error']['detail']).lower())
        self.assertFalse((self.root / '.dexter/dexter.db').exists())

    def test_configuration_restart_does_not_disconnect_attached_teammate(self):
        subprocess.run([BINARY, 'init', str(self.root)], env=self.env, capture_output=True, check=True)
        spec = importlib.util.spec_from_file_location('dx_stdlib_client', DX)
        client = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(client)
        session = client.Session(Path(BINARY), self.root, 15, env=self.env)
        try:
            session.initialize(self.root)
            code, report = self.invoke('start', stdlib=STDLIB)
            self.assertNotEqual(code, 0, report)
            self.assertEqual(report['error']['kind'], 'process')
            self.assertFalse((self.root / '.dexter/dx/stdlib.json').exists())
            self.assertTrue(session.request('textDocument/documentSymbol', {
                'textDocument': {'uri': (self.root / 'sample.ex').as_uri()}}))
        finally:
            session.close()
        code, report = self.invoke('start', stdlib=STDLIB)
        self.assertEqual(code, 0, report)


if __name__ == '__main__':
    unittest.main()
