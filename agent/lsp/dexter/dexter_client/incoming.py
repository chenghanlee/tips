"""Lexical source owners for Dexter reference lines, using Elixir's public parser."""

import json
import subprocess
from collections import Counter
from pathlib import Path

from .edits import Snapshot, digest, uri_path
from .protocol import DxError, JsonObject, Session


def read_callers(
    root: Path, references: list[JsonObject]
) -> tuple[list[JsonObject], Snapshot, list[JsonObject]]:
    by_uri: dict[str, set[int]] = {}
    for reference in references:
        by_uri.setdefault(reference["uri"], set()).add(reference["range"]["start"]["line"] + 1)
    files: list[JsonObject] = []
    sources: Snapshot = {}
    unavailable: list[JsonObject] = []
    for uri, lines in sorted(by_uri.items()):
        name = uri
        try:
            path = uri_path(root, uri)
            name = str(path)
            data = path.read_bytes()
            source = data.decode("utf-8")
        except (DxError, OSError, UnicodeDecodeError) as error:
            unavailable.extend(
                {"path": name, "line": line, "reason": "source_unavailable", "detail": str(error)}
                for line in sorted(lines)
            )
            continue
        sources[path] = data
        files.append({"path": name, "source": source, "lines": sorted(lines)})
    return files, sources, unavailable


def parse_owners(
    root: Path, target: JsonObject, files: list[JsonObject], timeout: float
) -> JsonObject:
    if not files:
        return {"sites": [], "unavailable": []}
    helper = Path(__file__).resolve().parents[1] / "owners.exs"
    try:
        process = subprocess.run(  # noqa: S603
            ["elixir", str(helper)],  # noqa: S607
            cwd=root,
            input=json.dumps({"target": target, "files": files}),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise DxError("incoming_parser", "Elixir ownership parser timed out") from error
    if process.returncode:
        raise DxError("incoming_parser", process.stderr or process.stdout)
    parsed: JsonObject = json.loads(process.stdout)
    expected = Counter((file["path"], line) for file in files for line in file["lines"])
    actual = Counter(
        (site["path"], site["line"]) for site in parsed["sites"] + parsed["unavailable"]
    )
    if actual != expected:
        raise DxError("incoming_parser", "Parser must account for each reference line exactly once")
    for site in parsed["sites"]:
        owner = site["owner"]
        if (
            site["status"] != "resolved"
            or site["kind"] != "call"
            or not owner["line"] <= site["line"] <= owner["end_line"]
        ):
            raise DxError("incoming_parser", "Parser returned an invalid source owner")
    return parsed


def incoming_calls(
    session: Session, root: Path, item: JsonObject, report: JsonObject
) -> JsonObject:
    target = item.get("data", {})
    if not target.get("module") or not target.get("function"):
        raise DxError("incoming_target", "Prepared item has no module/function identity")
    references: list[JsonObject] = (
        session.request(
            "textDocument/references",
            {
                "textDocument": {"uri": item["uri"]},
                "position": item["selectionRange"]["start"],
                "context": {"includeDeclaration": False},
            },
        )
        or []
    )
    files, sources, unavailable = read_callers(root, references)
    parsed = parse_owners(root, target, files, session.timeout)
    for path, data in sources.items():
        try:
            stable = path.read_bytes() == data
        except OSError:
            stable = False
        if not stable:
            raise DxError("changed_base", f"Caller source changed during lookup: {path}")
    report.update(
        result_kind="source_call_owners_at_indexed_reference_lines",
        positions="1-based source lines; not exact LSP ranges",
        block_followups="unsupported",
        upstream_reference_count=len(references),
        caller_sources=[
            {"path": str(path), "sha256": digest(data)} for path, data in sources.items()
        ],
    )
    return {"sites": parsed["sites"], "unavailable": unavailable + parsed["unavailable"]}
