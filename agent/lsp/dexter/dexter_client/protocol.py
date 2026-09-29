"""LSP framing, subprocess ownership, and wire payloads."""

import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time
from collections.abc import Generator, Sequence
from contextlib import ExitStack, contextmanager, suppress
from pathlib import Path
from typing import Any, BinaryIO, TypedDict, cast

# LSP objects are open records (including server-specific extension fields).
# Keep that flexibility at the wire/report boundary; local state has concrete types.
type JsonObject = dict[str, Any]


class CommandResult(TypedDict):
    exit_code: int
    stdout: str
    stderr: str


class DxError(Exception):
    def __init__(self, kind: str, detail: object) -> None:
        super().__init__(str(detail))
        self.kind, self.detail = kind, detail


def executable_args(
    argv: Sequence[str], root: Path, env: dict[str, str] | None = None
) -> list[str]:
    executable = argv[0]
    if os.sep in executable:
        resolved = str((root / executable).resolve(strict=True))
    else:
        resolved = shutil.which(executable, path=(env or os.environ).get("PATH"))
        if resolved is None:
            raise FileNotFoundError(executable)
    return [resolved, *argv[1:]]


def spawn_process(
    argv: Sequence[str],
    root: Path,
    env: dict[str, str] | None = None,
    stderr: BinaryIO | int = subprocess.PIPE,
) -> subprocess.Popen[bytes]:
    # Reviewed boundary: explicit executable, no shell, piped input/output. Session
    # supplies only the audited Dexter binary; tests use their own Python child.
    return subprocess.Popen(  # noqa: S603
        executable_args(argv, root, env),
        cwd=root,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=stderr,
        env={"DEXTER_DAEMON_IDLE_TIMEOUT": "0", **(os.environ if env is None else env)},
    )


def command(
    argv: Sequence[str], root: Path, timeout: float, env: dict[str, str] | None = None
) -> CommandResult:
    try:
        # Reviewed boundary: resolved executable, argv list, no shell. The Dexter
        # caller verifies its checksum; other callers use fixed Git/Elixir verbs.
        # Stdin-derived path arguments are absolute paths checked by bound_path.
        p = subprocess.run(  # noqa: S603
            executable_args(argv, root, env),
            cwd=root,
            capture_output=True,
            timeout=timeout,
            env={"DEXTER_DAEMON_IDLE_TIMEOUT": "0", **(os.environ if env is None else env)},
        )
    except subprocess.TimeoutExpired as e:
        raise DxError("timeout", {"command": argv, "seconds": timeout}) from e
    result: CommandResult = {
        "exit_code": p.returncode,
        "stdout": p.stdout.decode(errors="replace"),
        "stderr": p.stderr.decode(errors="replace"),
    }
    if p.returncode:
        raise DxError("process", result)
    return result


@contextmanager
def frontend_log() -> Generator[BinaryIO]:
    with tempfile.TemporaryFile() as handle:
        yield handle


class Session:
    def __init__(
        self, binary: Path, root: Path, timeout: float, env: dict[str, str] | None = None
    ) -> None:
        self.timeout, self.serial = timeout, 0
        self.events: list[JsonObject] = []
        self.messages: queue.Queue[JsonObject | Exception] = queue.Queue()
        self.resources = ExitStack()
        self.log = self.resources.enter_context(frontend_log())
        try:
            self.proc = spawn_process([str(binary), "-C", str(root), "lsp"], root, env, self.log)
        except BaseException:
            self.resources.close()
            raise
        if self.proc.stdin is None or self.proc.stdout is None:
            self.resources.close()
            raise DxError("transport", "LSP pipes were not created")
        self.stdin, self.stdout = self.proc.stdin, self.proc.stdout
        self.reader = threading.Thread(target=self.read_frames, daemon=True)
        self.reader.start()

    def read_frames(self) -> None:
        try:
            while True:
                headers: dict[str, str] = {}
                while True:
                    line = self.stdout.readline()
                    if not line:
                        raise EOFError("LSP frontend closed stdout")
                    if line in (b"\r\n", b"\n"):
                        break
                    key, value = line.decode("ascii").split(":", 1)
                    headers[key.lower()] = value.strip()
                size = int(headers["content-length"])
                if not 0 <= size <= 64 * 1024 * 1024:
                    raise ValueError("Invalid LSP frame length")
                body = self.stdout.read(size)
                if len(body) != size:
                    raise EOFError("Truncated LSP frame")
                message = json.loads(body)
                if not isinstance(message, dict):
                    raise ValueError("LSP frame must contain an object")
                self.messages.put(cast(JsonObject, message))
        except Exception as e:
            self.messages.put(e)

    def send(self, obj: JsonObject) -> None:
        body = json.dumps({"jsonrpc": "2.0", **obj}, ensure_ascii=False).encode()
        self.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.stdin.flush()

    def notify(self, method: str, params: JsonObject) -> None:
        self.send({"method": method, "params": params})

    def receive(self, deadline: float) -> JsonObject | None:
        try:
            msg = self.messages.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty as e:
            raise DxError("timeout", "LSP response/notification deadline expired") from e
        if isinstance(msg, Exception):
            raise DxError("transport", str(msg))
        if "method" in msg:
            self.events.append(msg)
            if "id" in msg:
                if msg["method"] == "workspace/configuration":
                    self.send(
                        {
                            "id": msg["id"],
                            "result": [None for _ in msg.get("params", {}).get("items", [])],
                        }
                    )
                else:
                    # In particular: no pretend watcher, edit or user-interaction support.
                    self.send(
                        {
                            "id": msg["id"],
                            "error": {
                                "code": -32601,
                                "message": "dx does not implement " + msg["method"],
                            },
                        }
                    )
            return None
        return msg

    def request(
        self, method: str, params: JsonObject | None = None, timeout: float | None = None
    ) -> Any:
        self.serial += 1
        ident = self.serial
        self.send({"id": ident, "method": method, "params": params or {}})
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        try:
            while True:
                msg = self.receive(deadline)
                if msg is not None and msg.get("id") == ident:
                    if "error" in msg:
                        raise DxError("lsp", msg["error"])
                    if "result" not in msg:
                        raise DxError("protocol", msg)
                    return msg["result"]
        except DxError as e:
            if e.kind == "timeout":
                with suppress(OSError):
                    self.notify("$/cancelRequest", {"id": ident})
            raise

    def initialize(self, root: Path) -> JsonObject:
        result = self.request(
            "initialize",
            {
                "processId": os.getpid(),
                "clientInfo": {"name": "tips-dx-prototype", "version": "0.1"},
                "rootUri": root.as_uri(),
                "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
                "capabilities": {
                    "general": {"positionEncodings": ["utf-16"]},
                    "workspace": {
                        "workspaceEdit": {
                            "documentChanges": True,
                            "resourceOperations": ["create", "rename", "delete"],
                        }
                    },
                    "textDocument": {"completion": {"completionItem": {"snippetSupport": True}}},
                },
            },
        )
        if result["capabilities"].get("positionEncoding", "utf-16") != "utf-16":
            raise DxError("encoding", "Unsupported server position encoding")
        startup = os.pread(self.log.fileno(), 1024 * 1024, 0).decode(errors="replace")
        if f"starting (root: {root}, daemon log: " not in startup:
            raise DxError(
                "isolation",
                {"message": "Pinned proxy did not confirm the requested root", "stderr": startup},
            )
        self.notify("initialized", {})
        return result

    def open(self, path: Path, text: str) -> None:
        language = "phoenix-heex" if path.suffix == ".heex" else "elixir"
        self.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": path.as_uri(),
                    "languageId": language,
                    "version": 1,
                    "text": text,
                }
            },
        )

    def diagnostics(self, uri: str) -> JsonObject:
        deadline = time.monotonic() + self.timeout
        while True:
            for event in reversed(self.events):
                if (
                    event["method"] == "textDocument/publishDiagnostics"
                    and event["params"]["uri"] == uri
                ):
                    return event["params"]
            self.receive(deadline)

    def close(self) -> str:
        try:
            if self.proc.poll() is None:
                self.request("shutdown", timeout=2)
                self.notify("exit", {})
                self.stdin.close()
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
        self.stdin.close()
        self.stdout.close()
        self.log.seek(0)
        stderr = self.log.read().decode(errors="replace")
        self.resources.close()
        return stderr
