"""Adversarial subprocess tests: errors must never become empty answers."""

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

from agent.lsp.dexter.dexter_client import protocol as dx
from agent.lsp.dexter.tests.support import dx_error
from agent.teams.team import execute

SERVER = r"""#!/usr/bin/env python3
import sys,json
if sys.argv[-1]=='reindex':print('Fixture reindex');sys.exit(0)
sys.stderr.write('starting (root: %s, daemon log: /fixture.log)\n'%sys.argv[2])
sys.stderr.flush()

def send(o):
 b=json.dumps({'jsonrpc':'2.0',**o},ensure_ascii=False).encode()
 sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(b)).encode()+b);sys.stdout.buffer.flush()
while True:
 headers={}
 while True:
  line=sys.stdin.buffer.readline()
  if not line:sys.exit(0)
  if line==b'\r\n':break
  k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
 m=json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
 method=m.get('method')
 if method=='exit':break
 if method=='die':sys.exit(7)
 if method=='hang':continue
 if method=='initialize':send({'id':m['id'],'result':{'capabilities':{}}});continue
 if method=='textDocument/definition':
  send({'id':m['id'],'result':[{'uri':'file:///bad.ex','range':{}}]});continue
 if method=='error':
  error={'code':-32603,'message':'upstream failed','data':{'path':'é.ex'}}
  send({'id':m['id'],'error':error});continue
 if method=='watch':
  send({'id':'register','method':'client/registerCapability','params':{'registrations':[]}});continue
 if m.get('id')=='register':
  send({'id':1,'result':m});continue
 if 'id' in m:send({'id':m['id'],'result':[]})
"""


class Protocol(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        binary = self.root / "server"
        binary.write_text(SERVER)
        binary.chmod(0o755)
        self.session = dx.Session(binary, self.root, 3)

    def tearDown(self) -> None:
        self.session.close()
        assert self.session.proc.poll() is not None
        self.temp.cleanup()

    def test_error_retains_code_and_data(self) -> None:
        error = dx_error(lambda: self.session.request("error"))
        assert error.kind == "lsp"
        assert error.detail == {
            "code": -32603,
            "message": "upstream failed",
            "data": {"path": "é.ex"},
        }
        assert self.session.request("empty") == []

    def test_timeout_is_error(self) -> None:
        error = dx_error(lambda: self.session.request("hang", timeout=0.4))
        assert error.kind == "timeout"

    def test_crash_is_error(self) -> None:
        error = dx_error(lambda: self.session.request("die"))
        assert error.kind == "transport"

    def test_watcher_registration_is_honestly_rejected(self) -> None:
        response = self.session.request("watch")
        assert response["error"]["code"] == -32601

    def test_malformed_location_returns_json_error_instead_of_traceback(self) -> None:
        execute(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "mix.exs").write_text("# protocol fixture\n")
        sources = self.root / "sources/lib"
        (sources / "elixir/lib").mkdir(parents=True)
        (sources / "elixir/lib/enum.ex").write_text("# unused protocol fixture\n")
        (sources.parent / "VERSION").write_text("0.0.0")
        state = self.root / ".dexter/dx"
        state.mkdir(parents=True)
        (state.parent / "dexter.db").touch()
        (state / "stdlib.json").write_text(
            json.dumps({"root": str(sources.resolve()), "version": "0.0.0"})
        )
        binary = self.root / "server"
        result = execute(
            [
                sys.executable,
                str(Path(__file__).resolve().parents[1] / "dx.py"),
                "--root",
                str(self.root),
                "--binary",
                str(binary),
                "--sha256",
                hashlib.sha256(binary.read_bytes()).hexdigest(),
                "definition",
            ],
            input_text='{"file":"mix.exs"}',
            timeout=10,
        )
        assert result.returncode == 1
        report = json.loads(result.stdout)
        assert not report["ok"]
        assert report["error"]["kind"] == "KeyError"
        assert report["result"][0]["range"] == {}
        assert "Traceback" not in result.stderr


if __name__ == "__main__":
    unittest.main()
