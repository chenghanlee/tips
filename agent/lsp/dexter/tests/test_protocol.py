"""Adversarial subprocess tests: errors must never become empty answers."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('dx', Path(__file__).resolve().parents[1] / 'dx.py')
dx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dx)

SERVER = r'''#!/usr/bin/env python3
import sys,json

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
 if method=='error':send({'id':m['id'],'error':{'code':-32603,'message':'upstream failed','data':{'path':'é.ex'}}});continue
 if method=='watch':send({'id':'register','method':'client/registerCapability','params':{'registrations':[]}});continue
 if m.get('id')=='register':
  send({'id':1,'result':m});continue
 if 'id' in m:send({'id':m['id'],'result':[]})
'''


class Protocol(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        binary = self.root / 'server'
        binary.write_text(SERVER)
        binary.chmod(0o755)
        self.session = dx.Session(binary, self.root, 3)

    def tearDown(self):
        self.session.close()
        self.assertIsNotNone(self.session.proc.poll())
        self.temp.cleanup()

    def test_error_retains_code_and_data(self):
        with self.assertRaises(dx.Failure) as error:
            self.session.request('error')
        self.assertEqual(error.exception.kind, 'lsp')
        self.assertEqual(error.exception.detail['data'], {'path':'é.ex'})
        self.assertEqual(self.session.request('empty'), [])

    def test_timeout_is_error(self):
        with self.assertRaises(dx.Failure) as error:
            self.session.request('hang', timeout=0.4)
        self.assertEqual(error.exception.kind, 'timeout')

    def test_crash_is_error(self):
        with self.assertRaises(dx.Failure) as error:
            self.session.request('die')
        self.assertEqual(error.exception.kind, 'transport')

    def test_watcher_registration_is_honestly_rejected(self):
        response = self.session.request('watch')
        self.assertEqual(response['error']['code'], -32601)


if __name__ == '__main__':
    unittest.main()
