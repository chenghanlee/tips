"""CLI arguments, root verification, presentation, and exit status."""

import argparse
import json
import os
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any, cast
from urllib.parse import unquote

from .edits import digest
from .protocol import DxError, JsonObject, command
from .workflows import METHODS
from .workspace import Worktree, operation_lock, walk_sources

REVISION = "cd099f31b7701803292584887bb614628f721b0a"
# This is the audited local build, not a portable reproducible-build checksum.
DEFAULT_SHA256 = "c27410b4424dbccf1053f23a7faa6b3c1d4fcfd1d039589ba7d06d72047da63a"


class Arguments(argparse.Namespace):
    root: Path
    binary: Path
    sha256: str | None
    timeout: float
    json: bool
    operation: str


def compact_report(report: JsonObject) -> JsonObject:
    if not report.get("ok") or report["operation"] in ("start", "stop", "reindex", "capabilities"):
        return report
    hidden = {
        "upstream_revision",
        "binary_sha256",
        "warnings",
        "frontend_stderr",
        "reconcile",
        "notifications",
    }
    result = {key: value for key, value in report.items() if key not in hidden}
    events = [
        event
        for event in report.get("notifications", [])
        if event.get("method") == "textDocument/publishDiagnostics"
        or (
            event.get("method") in ("window/logMessage", "window/showMessage")
            and event.get("params", {}).get("type") in (1, 2)
        )
    ]
    if events:
        result["notifications"] = events
    if report["operation"] in (
        "definition",
        "references",
        "type-definition",
        "declaration",
        "implementation",
    ):
        locations = report.get("result")
        if isinstance(locations, list):
            rendered: list[Any] = []
            for value in cast(list[Any], locations):
                location: Any = value
                if isinstance(location, dict) and set(cast(JsonObject, location)) == {
                    "uri",
                    "range",
                }:
                    location = cast(JsonObject, location)
                    uri: str = location["uri"]
                    prefix = Path(report["root"]).as_uri() + "/"
                    path = unquote(uri[len(prefix) :]) if uri.startswith(prefix) else uri
                    start, end = location["range"]["start"], location["range"]["end"]
                    rendered.append(
                        f"{path}:{start['line'] + 1}:{start['character'] + 1}"
                        f"-{end['line'] + 1}:{end['character'] + 1}"
                    )
                else:
                    rendered.append(location)
            result["result"] = rendered
    return result


def parse_arguments(argv: Sequence[str] | None) -> Arguments:
    parser = argparse.ArgumentParser(
        description=(
            "Experimental saved-file client for an audited Dexter build. Python stdlib only."
        )
    )
    parser.add_argument("--root", required=True, type=Path, help="Exact Git worktree/Mix root")
    parser.add_argument(
        "--binary",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "vendor/dexter",
        help="Audited Dexter executable; defaults to local vendor build",
    )
    parser.add_argument(
        "--sha256",
        default=None,
        help="Checksum of your audited build; defaults to local build manifest",
    )
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument(
        "--json",
        action="store_true",
        help="Full protocol report; default is compact JSON with readable navigation locations",
    )
    parser.add_argument(
        "operation",
        choices=[*METHODS, "capabilities", "diagnostics", "start", "stop", "reindex", "write"],
    )
    return parser.parse_args(argv, namespace=Arguments())


def verify_root(args: Arguments, report: JsonObject) -> tuple[Path, Path]:
    root, binary = args.root.resolve(strict=True), args.binary.resolve(strict=True)
    actual = command(["git", "rev-parse", "--show-toplevel"], root, args.timeout)["stdout"].strip()
    if root != Path(actual).resolve() or not (root / "mix.exs").is_file():
        raise DxError("scope", "--root must be the exact Git worktree root containing mix.exs")
    checksum = args.sha256
    if checksum is None:
        manifest_path = Path(__file__).resolve().parents[1] / "vendor/build.json"
        manifest: JsonObject = (
            json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
        )
        if (
            manifest.get("revision") == REVISION
            and Path(manifest.get("binary", "")).resolve() == binary
        ):
            checksum = manifest["sha256"]
        else:
            checksum = DEFAULT_SHA256
    if digest(binary.read_bytes()) != checksum:
        raise DxError("binary", "Checksum mismatch; audit the build and specify its checksum")
    report["root"], report["binary_sha256"] = str(root), checksum
    if args.operation != "stop":
        for _ in walk_sources(root):
            pass
    return root, binary


def run_operation(args: Arguments, params: JsonObject, report: JsonObject) -> None:
    root, binary = verify_root(args, report)
    worktree = Worktree(root, binary, args.timeout, dict(os.environ))
    # Check before opening the lock: do not create state through a symlink.
    if (
        worktree.state.parent.is_symlink()
        or worktree.state.is_symlink()
        or worktree.database.is_symlink()
    ):
        raise DxError("scope", "Dexter database and client state must not be symlinks")
    with operation_lock(worktree.state, args.timeout):
        config = worktree.prepare(args.operation, report)
        if args.operation in ("start", "stop", "reindex"):
            worktree.lifecycle(args.operation, params, report, config)
        else:
            worktree.perform(args.operation, params, report)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv)
    report: JsonObject = {
        "operation": args.operation,
        "freshness": "unverified",
        "upstream_revision": REVISION,
        "warnings": [
            "Reindex success is not proof of a current index: "
            "upstream can silently drop index errors.",
            "The worktree lock protects only cooperating writers.",
        ],
    }
    began = time.monotonic()
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        params: object = json.loads(raw) if raw.strip() else {}
        if not isinstance(params, dict):
            raise DxError("input", "stdin must contain a JSON object")
        run_operation(args, cast(JsonObject, params), report)
        report["ok"] = True
        output = report if args.json else compact_report(report)
    except (
        DxError,
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        KeyboardInterrupt,
    ) as error:
        report["ok"] = False
        report["error"] = {
            "kind": error.kind if isinstance(error, DxError) else type(error).__name__,
            "detail": error.detail if isinstance(error, DxError) else str(error),
        }
        output = report
    output["elapsed_ms"] = round((time.monotonic() - began) * 1000, 1)
    print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0 if report["ok"] else 1
