#!/usr/bin/env python3
"""Experimental saved-file client for pinned, unmodified Dexter. Python stdlib only."""
import argparse
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlparse
import uuid

REVISION = 'cd099f31b7701803292584887bb614628f721b0a'
# This is the audited local build, not a portable reproducible-build checksum.
DEFAULT_SHA256 = 'c27410b4424dbccf1053f23a7faa6b3c1d4fcfd1d039589ba7d06d72047da63a'
METHODS = {
    'definition': 'textDocument/definition',
    'type-definition': 'textDocument/typeDefinition',
    'declaration': 'textDocument/declaration',
    'implementation': 'textDocument/implementation',
    'references': 'textDocument/references',
    'hover': 'textDocument/hover',
    'highlights': 'textDocument/documentHighlight',
    'symbols': 'textDocument/documentSymbol',
    'workspace-symbols': 'workspace/symbol',
    'signature': 'textDocument/signatureHelp',
    'completion': 'textDocument/completion',
    'folding': 'textDocument/foldingRange',
    'code-actions': 'textDocument/codeAction',
    'format': 'textDocument/formatting',
    'prepare-rename': 'textDocument/prepareRename',
    'rename': 'textDocument/rename',
    'call-hierarchy': 'textDocument/prepareCallHierarchy',
    'incoming-calls': 'callHierarchy/incomingCalls',
    'outgoing-calls': 'callHierarchy/outgoingCalls',
}


class Failure(Exception):
    def __init__(self, kind, detail):
        super().__init__(str(detail))
        self.kind, self.detail = kind, detail


def digest(data):
    return hashlib.sha256(data).hexdigest()


def command(argv, root, timeout, env=None):
    try:
        p = subprocess.run(argv, cwd=root, capture_output=True, timeout=timeout,
                           env={'DEXTER_DAEMON_IDLE_TIMEOUT': '0', **(os.environ if env is None else env)})
    except subprocess.TimeoutExpired as e:
        raise Failure('timeout', {'command': argv, 'seconds': timeout}) from e
    result = {'exit_code': p.returncode, 'stdout': p.stdout.decode(errors='replace'),
              'stderr': p.stderr.decode(errors='replace')}
    if p.returncode:
        raise Failure('process', result)
    return result


def stdlib_config(value, root, timeout, check_toolchain=False):
    if not value:
        raise Failure('stdlib', 'Run dx start with DEXTER_ELIXIR_LIB_ROOT pointing to the lib directory of matching Elixir sources')
    try:
        path = Path(value).expanduser().resolve(strict=True)
        with (path / 'elixir/lib/enum.ex').open('rb') as source:
            if not source.read(1):
                raise ValueError('enum.ex is empty')
        version = (path.parent / 'VERSION').read_text().strip()
    except (OSError, ValueError) as e:
        raise Failure('stdlib', f'Expected Elixir sources at {value}/elixir/lib/enum.ex and ../VERSION: {e}') from e
    if check_toolchain:
        installed = command(['elixir', '--short-version'], root, timeout)['stdout'].strip()
        if version != installed:
            raise Failure('stdlib', f'Elixir source version {version} does not match the worktree toolchain {installed}')
    return {'root': str(path), 'version': version}


def bound_path(root, name):
    path = (root / name).resolve()
    if not path.is_relative_to(root) or path == root:
        raise Failure('scope', 'File must be inside the bound worktree')
    rel = path.relative_to(root)
    if any(p in {'.git', '.dexter', '_build', 'deps', '.worktrees'} for p in rel.parts):
        raise Failure('scope', 'Generated, dependency, nested-worktree and Git files are not writable inputs')
    # Refuse files in a nested checkout even if lexically under the bound root.
    for parent in path.parents:
        if parent == root:
            break
        if (parent / '.git').exists() or (parent / '.dexter/dexter.db').exists():
            raise Failure('scope', 'File belongs to a nested worktree')
    return path


def uri_path(root, uri):
    parsed = urlparse(uri)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise Failure('edit', 'Only local file URIs are supported')
    return bound_path(root, unquote(parsed.path))


@contextmanager
def operation_lock(state, timeout):
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'operation.lock').open('a') as handle:
        end = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = os.fstat(handle.fileno())
                try:
                    named = (state / 'operation.lock').stat()
                except FileNotFoundError as e:
                    raise Failure('lock_replaced', 'Lock file was deleted while acquiring it') from e
                if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
                    raise Failure('lock_replaced', 'Lock file changed while acquiring it; retry after checking worktree state')
                break
            except BlockingIOError:
                if time.monotonic() >= end:
                    raise Failure('lock_timeout', 'Another cooperating operation holds this worktree')
                time.sleep(0.025)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


class Session:
    def __init__(self, binary, root, timeout, env=None):
        self.timeout, self.events, self.serial = timeout, [], 0
        self.messages = queue.Queue()
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen([str(binary), '-C', str(root), 'lsp'], cwd=root,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                     env={'DEXTER_DAEMON_IDLE_TIMEOUT': '0', **(os.environ if env is None else env)})
        self.reader = threading.Thread(target=self.read_frames, daemon=True)
        self.reader.start()

    def read_frames(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.proc.stdout.readline()
                    if not line:
                        raise EOFError('LSP frontend closed stdout')
                    if line in (b'\r\n', b'\n'):
                        break
                    key, value = line.decode('ascii').split(':', 1)
                    headers[key.lower()] = value.strip()
                size = int(headers['content-length'])
                if not 0 <= size <= 64 * 1024 * 1024:
                    raise ValueError('Invalid LSP frame length')
                body = self.proc.stdout.read(size)
                if len(body) != size:
                    raise EOFError('Truncated LSP frame')
                self.messages.put(json.loads(body))
        except Exception as e:
            self.messages.put(e)

    def send(self, obj):
        body = json.dumps({'jsonrpc': '2.0', **obj}, ensure_ascii=False).encode()
        self.proc.stdin.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
        self.proc.stdin.flush()

    def notify(self, method, params):
        self.send({'method': method, 'params': params})

    def receive(self, deadline):
        try:
            msg = self.messages.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty as e:
            raise Failure('timeout', 'LSP response/notification deadline expired') from e
        if isinstance(msg, Exception):
            raise Failure('transport', str(msg))
        if 'method' in msg:
            self.events.append(msg)
            if 'id' in msg:
                if msg['method'] == 'workspace/configuration':
                    self.send({'id': msg['id'], 'result': [None for _ in msg.get('params', {}).get('items', [])]})
                else:
                    # In particular: no pretend watcher, edit or user-interaction support.
                    self.send({'id': msg['id'], 'error': {'code': -32601, 'message': 'dx does not implement ' + msg['method']}})
            return None
        return msg

    def request(self, method, params=None, timeout=None):
        self.serial += 1
        ident = self.serial
        self.send({'id': ident, 'method': method, 'params': params or {}})
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        try:
            while True:
                msg = self.receive(deadline)
                if msg is not None and msg.get('id') == ident:
                    if 'error' in msg:
                        raise Failure('lsp', msg['error'])
                    if 'result' not in msg:
                        raise Failure('protocol', msg)
                    return msg['result']
        except Failure as e:
            if e.kind == 'timeout':
                try:
                    self.notify('$/cancelRequest', {'id': ident})
                except OSError:
                    pass
            raise

    def initialize(self, root):
        result = self.request('initialize', {
            'processId': os.getpid(), 'clientInfo': {'name': 'tips-dx-prototype', 'version': '0.1'},
            'rootUri': root.as_uri(), 'workspaceFolders': [{'uri': root.as_uri(), 'name': root.name}],
            'capabilities': {'general': {'positionEncodings': ['utf-16']},
                             'workspace': {'workspaceEdit': {'documentChanges': True, 'resourceOperations': ['create', 'rename', 'delete']}},
                             'textDocument': {'completion': {'completionItem': {'snippetSupport': True}}}},
        })
        if result['capabilities'].get('positionEncoding', 'utf-16') != 'utf-16':
            raise Failure('encoding', 'Unsupported server position encoding')
        startup = os.pread(self.log.fileno(), 1024 * 1024, 0).decode(errors='replace')
        if f'starting (root: {root}, daemon log: ' not in startup:
            raise Failure('isolation', {'message': 'Pinned proxy did not confirm the requested root', 'stderr': startup})
        self.notify('initialized', {})
        return result

    def open(self, path, text):
        language = 'phoenix-heex' if path.suffix == '.heex' else 'elixir'
        self.notify('textDocument/didOpen', {'textDocument': {'uri': path.as_uri(), 'languageId': language, 'version': 1, 'text': text}})

    def diagnostics(self, uri):
        deadline = time.monotonic() + self.timeout
        while True:
            for event in reversed(self.events):
                if event['method'] == 'textDocument/publishDiagnostics' and event['params']['uri'] == uri:
                    return event['params']
            self.receive(deadline)

    def close(self):
        try:
            if self.proc.poll() is None:
                self.request('shutdown', timeout=2)
                self.notify('exit', {})
                self.proc.stdin.close()
                self.proc.wait(timeout=2)
        except (Exception, KeyboardInterrupt):
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        self.reader.join(timeout=1)
        self.proc.stdin.close()
        self.proc.stdout.close()
        self.log.seek(0)
        stderr = self.log.read().decode(errors='replace')
        self.log.close()
        return stderr


def offset(text, position):
    """Convert an LSP UTF-16 position to a Python string index; never round."""
    line, char = position['line'], position['character']
    parts = re.split(r'(\r\n|\r|\n)', text)
    lines = parts[::2]
    if line < 0 or char < 0 or line >= len(lines):
        raise Failure('position', position)
    prefix = sum(len(s) for s in parts[:2 * line])
    content = lines[line]
    units = 0
    for i, value in enumerate(content):
        if units == char:
            return prefix + i
        units += len(value.encode('utf-16-le')) // 2
    if units == char:
        return prefix + len(content)
    raise Failure('position', 'Column is beyond the line or splits a surrogate pair')


def edit_text(text, edits):
    spans = [(offset(text, e['range']['start']), offset(text, e['range']['end']), e['newText']) for e in edits]
    spans.sort(key=lambda s: (s[0], s[1]))
    end = -1
    for start, stop, _ in spans:
        if stop < start or start < end:
            raise Failure('edit', 'Invalid or overlapping text edits')
        end = stop
    for start, stop, replacement in reversed(spans):
        text = text[:start] + replacement + text[stop:]
    return text


def walk_sources(root):
    def failed(error):
        raise error
    for directory, dirs, files in os.walk(root, onerror=failed):
        # Dexter skips the first three. deps are legitimate read-only Mix inputs.
        if Path(directory) != root and ('.git' in dirs + files or
                                        ('.dexter' in dirs and (Path(directory) / '.dexter/dexter.db').is_file())):
            raise Failure('isolation', {'message': 'Root contains a nested checkout; use a leaf worktree',
                                        'nested_checkout': directory})
        dirs[:] = [d for d in dirs if d not in ('_build', '.git', 'node_modules', 'deps')]
        for name in files:
            if Path(name).suffix in ('.ex', '.exs', '.heex', '.leex'):
                yield Path(directory) / name


def source_snapshot(root):
    # Dexter ignores .gitignore. Capture ignored source too, or rename changes
    # in scratch copies would disappear from the snapshot and changed-file report.
    return {bound_path(root, path): path.read_bytes() for path in walk_sources(root)}


def save_snapshot(state, root, before):
    path = state / 'snapshots' / (uuid.uuid4().hex + '.json')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'root': str(root), 'git_status': command(['git', 'status', '--porcelain=v1', '-z'], root, 30)['stdout'],
                                'files': {str(p.relative_to(root)): base64.b64encode(v).decode() for p, v in before.items()}}))
    path.chmod(0o600)
    return str(path)


def apply_workspace_edit(root, edit, baseline):
    """Validate the entire proposal first, then write. Not a multi-file transaction."""
    if edit.get('changeAnnotations'):
        raise Failure('edit', 'Annotated edits need an explicit confirmation workflow')
    plan = dict(baseline)
    touched = set()
    changes = [{'textDocument': {'uri': uri}, 'edits': edits} for uri, edits in edit.get('changes', {}).items()]
    changes += edit.get('documentChanges', [])
    for change in changes:
        kind = change.get('kind')
        if kind in ('create', 'rename', 'delete'):
            path = uri_path(root, change.get('uri', change.get('oldUri')))
            if kind == 'create':
                if path in plan or path.exists():
                    raise Failure('edit', 'Refusing to overwrite an existing resource')
                plan[path] = b''
            elif kind == 'delete':
                if path not in plan:
                    raise Failure('edit', 'Delete target was not captured in the source snapshot')
                del plan[path]
            else:
                target = uri_path(root, change['newUri'])
                if path not in plan or target in plan or target.exists():
                    raise Failure('edit', 'Rename source missing or target already exists')
                plan[target] = plan.pop(path)
                touched.add(target)
            touched.add(path)
        elif 'textDocument' in change:
            path = uri_path(root, change['textDocument']['uri'])
            if path not in plan:
                raise Failure('edit', 'Edit target was not captured in the source snapshot')
            if change['textDocument'].get('version') not in (None, 1):
                raise Failure('edit', 'Unexpected document version')
            plan[path] = edit_text(plan[path].decode('utf-8'), change['edits']).encode('utf-8')
            touched.add(path)
        else:
            raise Failure('edit', {'unsupported_change': change})
    for path in touched:
        current = path.read_bytes() if path.exists() else None
        if current != baseline.get(path):
            raise Failure('changed_base', str(path))
    for path in sorted(touched):
        if path not in plan:
            path.unlink()
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            # The lock protects cooperating writers, not arbitrary filesystem writes.
            mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
            fd, temporary = tempfile.mkstemp(prefix='.dx-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as handle:
                    handle.write(plan[path])
                os.chmod(temporary, mode)
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return [str(p.relative_to(root)) for p in sorted(touched)]


def selected(items, params):
    if not items:
        raise Failure('selection', 'No candidate returned; this does not establish index freshness')
    index = params.get('select', 0)
    if isinstance(index, str):
        matches = [item for item in items if item.get('label', item.get('title')) == index]
        if len(matches) != 1:
            raise Failure('selection', 'Label/title must match exactly one candidate')
        return matches[0]
    if not isinstance(index, int) or not 0 <= index < len(items):
        raise Failure('selection', 'select must name a returned candidate index')
    return items[index]


def workflow(session, root, op, params, report, before):
    path = None
    request = {}
    if op != 'workspace-symbols':
        path = bound_path(root, params['file'])
        data = path.read_bytes()
        report['source'] = {'uri': path.as_uri(), 'sha256': digest(data)}
        if params.get('expected_sha256', digest(data)) != digest(data):
            raise Failure('changed_base', 'Input position refers to a different file revision')
        request = {'textDocument': {'uri': path.as_uri()}}
        position = {'line': params.get('line', 1) - 1, 'character': params.get('column', 1) - 1}
        offset(data.decode(), position)
        request['position'] = position
    else:
        request = {'query': params.get('query', '')}
    if op == 'references':
        request['context'] = {'includeDeclaration': params.get('include_declaration', True)}
    if op == 'rename':
        if params.get('apply') is not True:
            raise Failure('mutation', 'Rename can write inside Dexter; explicitly set apply=true')
        request['newName'] = params['new_name']
    if op in ('format', 'diagnostics'):
        session.open(path, data.decode())
        request['options'] = params.get('options', {'tabSize': 2, 'insertSpaces': True})
    if op == 'diagnostics':
        # Dexter publishes formatter/syntax diagnostics on formatting, not didOpen.
        session.request('textDocument/formatting', request)
        report['diagnostic_kind'] = 'syntax'
        return session.diagnostics(path.as_uri())
    if op == 'code-actions':
        request['range'] = params.get('range', {'start': position, 'end': position})
        request['context'] = {'diagnostics': params.get('diagnostics', [])}
    if op in ('incoming-calls', 'outgoing-calls'):
        items = session.request('textDocument/prepareCallHierarchy', request)
        report['prepared_items'] = items
        report['followup_sent'] = bool(items)
        if not items:
            return None
        request = {'item': selected(items, params)}
    result = session.request(METHODS[op], request)
    if op == 'format':
        report['syntax_diagnostics'] = session.diagnostics(path.as_uri())
        if any(d.get('severity') == 1 for d in report['syntax_diagnostics']['diagnostics']):
            raise Failure('formatter', report['syntax_diagnostics'])
    if op == 'completion' and ('select' in params or params.get('apply')):
        item = selected(result.get('items', []) if isinstance(result, dict) else result, params)
        item = session.request('completionItem/resolve', item)
        report['resolved_item'] = item
        if params.get('apply'):
            if item.get('command'):
                raise Failure('completion', 'Completion commands are not advertised by pinned Dexter')
            if item.get('insertTextFormat', 1) == 2 and 'insert_text' not in params:
                raise Failure('completion', 'Resolve exposes the snippet; supply insert_text with the filled-in plain text to apply it')
            edit = item.get('textEdit')
            if edit and 'range' not in edit:
                edit = {'range': edit['replace'], 'newText': edit['newText']}
            if not edit:
                # A terminal has no editor-selected word range. Never guess and duplicate a prefix.
                if 'replace_range' not in params:
                    raise Failure('completion', 'This item needs an explicit zero-based UTF-16 replace_range')
                edit = {'range': params['replace_range'], 'newText': item.get('insertText', item['label'])}
            if 'insert_text' in params:
                edit = {**edit, 'newText': params['insert_text']}
            report['applied'] = apply_workspace_edit(root, {'changes': {path.as_uri(): [edit, *item.get('additionalTextEdits', [])]}}, before)
    if params.get('apply') and op in ('format', 'code-actions', 'rename'):
        edit = result
        if op == 'format':
            edit = {'changes': {path.as_uri(): result or []}}
        elif op == 'code-actions':
            action = selected(result, params)
            report['selected_action'] = action
            if action.get('command') or action.get('disabled'):
                raise Failure('code_action', 'Command/disabled actions are not supported by this pinned workflow')
            edit = action.get('edit', {})
        # Rename may already have changed disk. Apply its returned local-variable/alias edits
        # against the original snapshot: reject an unexpected combination of overlapping writes.
        report['applied'] = apply_workspace_edit(root, edit or {}, before)
    if path and not params.get('apply') and path.read_bytes() != data:
        raise Failure('changed_base', 'Source changed during the lookup; result rejected')
    return result


def compact_report(report):
    if not report.get('ok') or report['operation'] in ('start', 'stop', 'reindex', 'capabilities'):
        return report
    hidden = {'upstream_revision', 'binary_sha256', 'warnings', 'frontend_stderr', 'reconcile', 'notifications'}
    result = {key: value for key, value in report.items() if key not in hidden}
    events = [event for event in report.get('notifications', [])
              if event.get('method') == 'textDocument/publishDiagnostics' or
              (event.get('method') in ('window/logMessage', 'window/showMessage') and
               event.get('params', {}).get('type') in (1, 2))]
    if events:
        result['notifications'] = events
    if report['operation'] in ('definition', 'references', 'type-definition', 'declaration', 'implementation'):
        locations = report.get('result')
        if isinstance(locations, list):
            rendered = []
            for location in locations:
                if isinstance(location, dict) and set(location) == {'uri', 'range'}:
                    uri = location['uri']
                    prefix = Path(report['root']).as_uri() + '/'
                    path = unquote(uri[len(prefix):]) if uri.startswith(prefix) else uri
                    start, end = location['range']['start'], location['range']['end']
                    rendered.append(f"{path}:{start['line']+1}:{start['character']+1}-{end['line']+1}:{end['character']+1}")
                else:
                    rendered.append(location)
            result['result'] = rendered
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path, help='Exact Git worktree/Mix root')
    parser.add_argument('--binary', type=Path, default=Path(__file__).resolve().parent / 'vendor/dexter', help='Pinned stock Dexter executable; defaults to local vendor build')
    parser.add_argument('--sha256', default=None, help='Checksum of your audited stock build; defaults to local build manifest')
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--json', action='store_true', help='Full protocol report; default is compact JSON with readable navigation locations')
    parser.add_argument('operation', choices=[*METHODS, 'capabilities', 'diagnostics', 'start', 'stop', 'reindex', 'write'])
    args = parser.parse_args(argv)
    report = {'operation': args.operation, 'freshness': 'unverified', 'upstream_revision': REVISION,
              'warnings': ['Reindex success is not proof of a current index: upstream can silently drop index errors.',
                           'The worktree lock protects only cooperating writers.']}
    began = time.monotonic()
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ''
        params = json.loads(raw) if raw.strip() else {}
        if not isinstance(params, dict):
            raise Failure('input', 'stdin must contain a JSON object')
        root, binary = args.root.resolve(strict=True), args.binary.resolve(strict=True)
        actual_root = Path(command(['git', 'rev-parse', '--show-toplevel'], root, args.timeout)['stdout'].strip()).resolve()
        if root != actual_root or not (root / 'mix.exs').is_file():
            raise Failure('scope', '--root must be the exact Git worktree root containing mix.exs')
        if args.sha256 is None:
            manifest_path = Path(__file__).resolve().parent / 'vendor/build.json'
            manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
            if manifest.get('revision') == REVISION and Path(manifest.get('binary', '')).resolve() == binary:
                args.sha256 = manifest['sha256']
            else:
                args.sha256 = DEFAULT_SHA256
        if digest(binary.read_bytes()) != args.sha256:
            raise Failure('binary', 'Checksum mismatch; use the pinned stock build or audit and specify its checksum')
        report['root'], report['binary_sha256'] = str(root), args.sha256
        if args.operation != 'stop':
            for _ in walk_sources(root):
                pass
        state = root / '.dexter' / 'dx'
        database = root / '.dexter/dexter.db'
        if state.parent.is_symlink() or state.is_symlink() or database.is_symlink():
            raise Failure('scope', 'Dexter database and client state must belong to this worktree, not symlinks')
        with operation_lock(state, args.timeout):
            config_path = state / 'stdlib.json'
            child_env = dict(os.environ)
            if args.operation != 'stop':
                if args.operation != 'start' and not database.is_file():
                    raise Failure('not_initialized', 'Run dx start first: this exact root needs its own database')
                saved = json.loads(config_path.read_text()) if config_path.exists() else {}
                value = (os.environ.get('DEXTER_ELIXIR_LIB_ROOT') or saved.get('root')) if args.operation == 'start' else saved.get('root')
                report['stdlib'] = {'status': 'unconfigured'}
                config = stdlib_config(value, root, args.timeout, check_toolchain=args.operation == 'start')
                if args.operation != 'start' and config != saved:
                    raise Failure('stdlib', 'Saved Elixir sources changed; run dx start again')
                child_env['DEXTER_ELIXIR_LIB_ROOT'] = config['root']
                if args.operation == 'start' and config != saved and database.is_file():
                    # An existing daemon keeps its old environment. Never force a
                    # teammate off: stock stop refuses while a client is attached.
                    report['restart'] = command([str(binary), '-C', str(root), 'stop'], root, args.timeout)
                report['stdlib'] = {'status': 'configured', **config}
            if args.operation == 'start' and not database.exists():
                report['init'] = command([str(binary), 'init', str(root)], root, args.timeout, env=child_env)
            if not database.is_file():
                raise Failure('not_initialized', 'Run dx start first: a database at this exact root prevents Dexter from selecting an ancestor')
            def reindex(target=None):
                return command([str(binary), '-C', str(root), 'reindex', *([str(target)] if target else [])], root, args.timeout, env=child_env)
            if args.operation in ('start', 'stop', 'reindex'):
                if args.operation == 'stop':
                    report['result'] = command([str(binary), '-C', str(root), 'stop'], root, args.timeout)
                else:
                    target = bound_path(root, params['file']) if 'file' in params else None
                    report['result'] = reindex(target)
                    report['reconcile'] = 'batch processed; success of each indexed file is unverified'
                    if args.operation == 'start':
                        config_path.write_text(json.dumps(config) + '\n')
            else:
                mutation = args.operation in ('rename', 'write') or params.get('apply') is True
                if params.get('apply') and args.operation not in ('rename', 'write', 'completion', 'code-actions', 'format'):
                    raise Failure('input', 'apply is not valid for this operation')
                before = source_snapshot(root) if mutation else {}
                if mutation:
                    recovery = before
                    if args.operation == 'write':
                        target = bound_path(root, params['file'])
                        recovery = {path: data for path, data in before.items() if path == target}
                    report['snapshot'] = save_snapshot(state, root, recovery)
                    report['mutation_completion'] = 'unverified; inspect changed files; no automatic rollback'
                try:
                    if args.operation == 'write':
                        path = bound_path(root, params['file'])
                        if path.suffix not in ('.ex', '.exs', '.heex', '.leex'):
                            raise Failure('scope', 'write currently supports source extensions .ex/.exs/.heex/.leex')
                        current = path.read_bytes() if path.exists() else None
                        expected = params['expected_sha256']
                        if (digest(current) if current is not None else None) != expected:
                            raise Failure('changed_base', 'Saved file no longer matches expected_sha256')
                        if current is None:
                            edit = {'documentChanges': [{'kind': 'create', 'uri': path.as_uri()}, {'textDocument': {'uri': path.as_uri()}, 'edits': [{'range': {'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}}, 'newText': params['text']}]}]}
                        else:
                            if path not in before:
                                raise Failure('scope', 'write currently supports source extensions .ex/.exs/.heex/.leex')
                            text = current.decode()
                            lines = re.split(r'\r\n|\r|\n', text)
                            end = {'line': len(lines)-1, 'character': len(lines[-1].encode('utf-16-le'))//2}
                            edit = {'changes': {path.as_uri(): [{'range': {'start': {'line': 0, 'character': 0}, 'end': end}, 'newText': params['text']}]}}
                        report['result'] = {'applied': apply_workspace_edit(root, edit, before)}
                    else:
                        report['reconcile'] = reindex()
                        session = Session(binary, root, args.timeout, env=child_env)
                        try:
                            capabilities = session.initialize(root)
                            report['result'] = capabilities if args.operation == 'capabilities' else workflow(session, root, args.operation, params, report, before)
                        finally:
                            report['frontend_stderr'] = session.close()
                            startup = re.search(re.escape(f'starting (root: {root}, daemon log: ') + r'([^\r\n]+)\)', report['frontend_stderr'])
                            if startup:
                                report['daemon_log'] = startup[1]
                            report['notifications'] = session.events
                finally:
                    if mutation:
                        after = source_snapshot(root)
                        changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
                        report['changed_files'] = [str(p.relative_to(root)) for p in changed]
                        report['post_reconcile'] = []
                        for path in changed:
                            try:
                                report['post_reconcile'].append({'path': str(path), 'result': reindex(path)})
                            except Failure as e:
                                report['post_reconcile'].append({'path': str(path), 'error': e.detail})
                        if any('error' in r for r in report['post_reconcile']):
                            raise Failure('post_reconcile', 'Mutation may be partial; see changed_files and snapshot')
        report['ok'] = True
    except (Failure, OSError, ValueError, KeyError, TypeError, KeyboardInterrupt) as e:
        report['ok'] = False
        report['error'] = {'kind': e.kind if isinstance(e, Failure) else type(e).__name__,
                           'detail': e.detail if isinstance(e, Failure) else str(e)}
    report['elapsed_ms'] = round((time.monotonic() - began) * 1000, 1)
    print(json.dumps(report if args.json else compact_report(report), ensure_ascii=False, separators=(',', ':')))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
