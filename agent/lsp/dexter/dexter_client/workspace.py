"""Own one worktree's daemon configuration and mutation lifecycle."""

import base64
import fcntl
import json
import os
import re
import time
import uuid
from collections.abc import Generator, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

from .edits import Snapshot, apply_workspace_edit, bound_path, digest
from .protocol import CommandResult, DxError, JsonObject, Session, command
from .workflows import workflow


class StdlibConfig(TypedDict):
    root: str
    version: str


@contextmanager
def operation_lock(state: Path, timeout: float) -> Generator[None]:
    state.mkdir(parents=True, exist_ok=True)
    with (state / "operation.lock").open("a") as handle:
        end = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held = os.fstat(handle.fileno())
                try:
                    named = (state / "operation.lock").stat()
                except FileNotFoundError as e:
                    raise DxError(
                        "lock_replaced", "Lock file was deleted while acquiring it"
                    ) from e
                if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
                    raise DxError(
                        "lock_replaced",
                        "Lock file changed while acquiring it; retry after checking worktree state",
                    )
                break
            except BlockingIOError as error:
                if time.monotonic() >= end:
                    raise DxError(
                        "lock_timeout", "Another cooperating operation holds this worktree"
                    ) from error
                time.sleep(0.025)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def walk_sources(root: Path) -> Iterator[Path]:
    def failed(error: OSError) -> None:
        raise error

    for directory, dirs, files in os.walk(root, onerror=failed):
        # Dexter skips the first three. deps are legitimate read-only Mix inputs.
        if Path(directory) != root and (
            ".git" in dirs + files
            or (".dexter" in dirs and (Path(directory) / ".dexter/dexter.db").is_file())
        ):
            raise DxError(
                "isolation",
                {
                    "message": "Root contains a nested checkout; use a leaf worktree",
                    "nested_checkout": directory,
                },
            )
        dirs[:] = [d for d in dirs if d not in ("_build", ".git", "node_modules", "deps")]
        for name in files:
            if Path(name).suffix in (".ex", ".exs", ".heex", ".leex"):
                yield Path(directory) / name


def source_snapshot(root: Path) -> Snapshot:
    # Dexter ignores .gitignore. Capture ignored source too, or rename changes
    # in scratch copies would disappear from the snapshot and changed-file report.
    return {bound_path(root, path): path.read_bytes() for path in walk_sources(root)}


def save_snapshot(state: Path, root: Path, before: Snapshot) -> str:
    path = state / "snapshots" / (uuid.uuid4().hex + ".json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "root": str(root),
                "git_status": command(["git", "status", "--porcelain=v1", "-z"], root, 30)[
                    "stdout"
                ],
                "files": {
                    str(p.relative_to(root)): base64.b64encode(v).decode()
                    for p, v in before.items()
                },
            }
        )
    )
    path.chmod(0o600)
    return str(path)


def stdlib_config(
    value: str | None, root: Path, timeout: float, check_toolchain: bool = False
) -> StdlibConfig:
    if not value:
        raise DxError(
            "stdlib",
            "Run dx start with DEXTER_ELIXIR_LIB_ROOT pointing to the lib directory "
            "of matching Elixir sources",
        )
    try:
        path = Path(value).expanduser().resolve(strict=True)
        with (path / "elixir/lib/enum.ex").open("rb") as source:
            if not source.read(1):
                raise ValueError("enum.ex is empty")
        version = (path.parent / "VERSION").read_text().strip()
    except (OSError, ValueError) as e:
        raise DxError(
            "stdlib", f"Expected Elixir sources at {value}/elixir/lib/enum.ex and ../VERSION: {e}"
        ) from e
    if check_toolchain:
        installed = command(["elixir", "--short-version"], root, timeout)["stdout"].strip()
        if version != installed:
            raise DxError(
                "stdlib",
                f"Elixir source version {version} does not match "
                f"the worktree toolchain {installed}",
            )
    return {"root": str(path), "version": version}


@dataclass
class Worktree:
    root: Path
    binary: Path
    timeout: float
    env: dict[str, str]

    @property
    def state(self) -> Path:
        return self.root / ".dexter/dx"

    @property
    def database(self) -> Path:
        return self.root / ".dexter/dexter.db"

    def stop(self) -> CommandResult:
        return command([str(self.binary), "-C", str(self.root), "stop"], self.root, self.timeout)

    def reindex(self, target: Path | None = None) -> CommandResult:
        return command(
            [str(self.binary), "-C", str(self.root), "reindex", *([str(target)] if target else [])],
            self.root,
            self.timeout,
            self.env,
        )

    def configure(self, op: str, report: JsonObject) -> StdlibConfig | None:
        if op == "stop":
            return None
        if op != "start" and not self.database.is_file():
            raise DxError(
                "not_initialized", "Run dx start first: this exact root needs its own database"
            )
        config_path = self.state / "stdlib.json"
        saved: JsonObject = json.loads(config_path.read_text()) if config_path.exists() else {}
        value = (
            (self.env.get("DEXTER_ELIXIR_LIB_ROOT") or saved.get("root"))
            if op == "start"
            else saved.get("root")
        )
        report["stdlib"] = {"status": "unconfigured"}
        config = stdlib_config(value, self.root, self.timeout, check_toolchain=op == "start")
        if op != "start" and config != saved:
            raise DxError("stdlib", "Saved Elixir sources changed; run dx start again")
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = config["root"]
        if op == "start" and config != saved and self.database.is_file():
            report["restart"] = self.stop()
        report["stdlib"] = {"status": "configured", **config}
        return config

    def prepare(self, op: str, report: JsonObject) -> StdlibConfig | None:
        config = self.configure(op, report)
        if op == "start" and not self.database.exists():
            report["init"] = command(
                [str(self.binary), "init", str(self.root)], self.root, self.timeout, self.env
            )
        if not self.database.is_file():
            raise DxError("not_initialized", "This exact root needs its own database")
        return config

    def lifecycle(
        self, op: str, params: JsonObject, report: JsonObject, config: StdlibConfig | None
    ) -> None:
        if op == "stop":
            report["result"] = self.stop()
            return
        target = bound_path(self.root, params["file"]) if "file" in params else None
        report["result"] = self.reindex(target)
        report["reconcile"] = "batch processed; success of each indexed file is unverified"
        if op == "start":
            (self.state / "stdlib.json").write_text(json.dumps(config) + "\n")

    def query(self, op: str, params: JsonObject, report: JsonObject, before: Snapshot) -> None:
        report["reconcile"] = self.reindex()
        session = Session(self.binary, self.root, self.timeout, self.env)
        try:
            capabilities = session.initialize(self.root)
            report["result"] = (
                capabilities
                if op == "capabilities"
                else workflow(session, self.root, op, params, report, before)
            )
        finally:
            stderr = session.close()
            report["frontend_stderr"], report["notifications"] = stderr, session.events
            startup = re.search(
                re.escape(f"starting (root: {self.root}, daemon log: ") + r"([^\r\n]+)\)", stderr
            )
            if startup:
                report["daemon_log"] = startup[1]

    def reconcile_mutation(self, before: Snapshot, report: JsonObject) -> None:
        after = source_snapshot(self.root)
        changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
        report["changed_files"] = [str(p.relative_to(self.root)) for p in changed]
        results: list[JsonObject] = []
        report["post_reconcile"] = results
        for path in changed:
            try:
                results.append({"path": str(path), "result": self.reindex(path)})
            except DxError as error:
                results.append({"path": str(path), "error": error.detail})
        if any("error" in row for row in results):
            raise DxError(
                "post_reconcile", "Mutation may be partial; see changed_files and snapshot"
            )

    def perform(self, op: str, params: JsonObject, report: JsonObject) -> None:
        mutation = op in ("rename", "write") or params.get("apply") is True
        if params.get("apply") and op not in (
            "rename",
            "write",
            "completion",
            "code-actions",
            "format",
        ):
            raise DxError("input", "apply is not valid for this operation")
        before = source_snapshot(self.root) if mutation else {}
        if mutation:
            recovery = before
            if op == "write":
                target = bound_path(self.root, params["file"])
                recovery = {path: data for path, data in before.items() if path == target}
            report["snapshot"] = save_snapshot(self.state, self.root, recovery)
            report["mutation_completion"] = (
                "unverified; inspect changed files; no automatic rollback"
            )
        try:
            if op == "write":
                report["result"] = {"applied": write_source(self.root, params, before)}
            else:
                self.query(op, params, report, before)
        finally:
            if mutation:
                self.reconcile_mutation(before, report)


def write_source(root: Path, params: JsonObject, before: Snapshot) -> list[str]:
    path = bound_path(root, params["file"])
    if path.suffix not in (".ex", ".exs", ".heex", ".leex"):
        raise DxError("scope", "write supports source extensions .ex/.exs/.heex/.leex")
    current = path.read_bytes() if path.exists() else None
    if (digest(current) if current is not None else None) != params["expected_sha256"]:
        raise DxError("changed_base", "Saved file no longer matches expected_sha256")
    end = {"line": 0, "character": 0}
    if current is not None:
        if path not in before:
            raise DxError("scope", "Write target was not captured in the source snapshot")
        lines = re.split(r"\r\n|\r|\n", current.decode())
        end = {"line": len(lines) - 1, "character": len(lines[-1].encode("utf-16-le")) // 2}
    changes: list[JsonObject] = []
    if current is None:
        changes.append({"kind": "create", "uri": path.as_uri()})
    changes.append(
        {
            "textDocument": {"uri": path.as_uri()},
            "edits": [
                {
                    "range": {"start": {"line": 0, "character": 0}, "end": end},
                    "newText": params["text"],
                }
            ],
        }
    )
    return apply_workspace_edit(root, {"documentChanges": changes}, before)
