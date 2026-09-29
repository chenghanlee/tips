"""Wide-impact edit coordinate and validation logic; no language-server mocks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('dx', Path(__file__).resolve().parents[1] / 'dx.py')
dx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dx)


class Edits(unittest.TestCase):
    def test_compact_output_keeps_every_location_and_actionable_notification(self):
        location = {'uri': 'file:///project/lib/a%20b.ex', 'range': {
            'start': {'line': 1, 'character': 2}, 'end': {'line': 3, 'character': 4}}}
        diagnostics = {'method': 'textDocument/publishDiagnostics', 'params': {'diagnostics': []}}
        warning = {'method': 'window/logMessage', 'params': {'type': 2, 'message': 'warning'}}
        error = {'method': 'window/showMessage', 'params': {'type': 1, 'message': 'error'}}
        report = {'operation': 'references', 'ok': True, 'root': '/project',
                  'freshness': 'unverified', 'result': [location] * 224,
                  'daemon_log': '/tmp/dexter-test/project.log',
                  'binary_sha256': 'static', 'notifications': [diagnostics, warning, error,
                      {'method': 'client/registerCapability'}]}
        compact = dx.compact_report(report)
        self.assertEqual(compact['result'], ['lib/a b.ex:2:3-4:5'] * 224)
        self.assertEqual(compact['notifications'], [diagnostics, warning, error])
        self.assertEqual(compact['freshness'], 'unverified')
        self.assertEqual(compact['daemon_log'], report['daemon_log'])
        self.assertNotIn('binary_sha256', compact)
        self.assertEqual(report['result'][0], location)
        report['ok'] = False
        self.assertIs(dx.compact_report(report), report)

    def test_utf16_crlf_and_overlaps(self):
        text = 'a😀b\r\nnext\r\n'
        edit = {'range': {'start': {'line': 0, 'character': 1}, 'end': {'line': 0, 'character': 3}}, 'newText': 'é'}
        self.assertEqual(dx.edit_text(text, [edit]), 'aéb\r\nnext\r\n')
        self.assertEqual(dx.offset('a\u2028b\nnext', {'line': 0, 'character': 3}), 3)
        self.assertEqual(dx.offset('ab\rc', {'line': 1, 'character': 1}), 4)
        with self.assertRaises(dx.Failure):
            dx.offset(text, {'line': 0, 'character': 2})
        with self.assertRaises(dx.Failure):
            dx.edit_text(text, [edit, edit])

    def test_validate_all_files_before_writing_and_preserve_dirty_base(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            a, b = root / 'a.ex', root / 'b.ex'
            a.write_text('dirty a')
            b.write_text('dirty b')
            before = {a: a.read_bytes(), b: b.read_bytes()}
            b.write_text('teammate edit')
            edit = {'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}, 'newText': '# new\n'}
            with self.assertRaises(dx.Failure):
                dx.apply_workspace_edit(root, {'changes': {a.as_uri(): [edit], b.as_uri(): [edit]}}, before)
            self.assertEqual(a.read_text(), 'dirty a')
            self.assertEqual(b.read_text(), 'teammate edit')

    def test_resource_order_and_scope(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            a, b = root / 'a.ex', root / 'b.ex'
            a.write_text('original')
            edits = {'documentChanges': [
                {'kind': 'rename', 'oldUri': a.as_uri(), 'newUri': b.as_uri()},
                {'textDocument': {'uri': b.as_uri()}, 'edits': [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 8}}, 'newText': 'updated'}]},
            ]}
            dx.apply_workspace_edit(root, edits, {a: a.read_bytes()})
            self.assertFalse(a.exists())
            self.assertEqual(b.read_text(), 'updated')
            with self.assertRaises(dx.Failure):
                dx.bound_path(root, '../sibling/lib.ex')


if __name__ == '__main__':
    unittest.main()
