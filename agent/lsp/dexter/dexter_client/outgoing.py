"""Outgoing call sites from source syntax, resolved by the existing Dexter session."""

import json
import subprocess
from pathlib import Path

from .protocol import DxError, JsonObject, Session


def parse_sites(root: Path, data: bytes, line: int, timeout: float) -> JsonObject:
    helper = Path(__file__).resolve().parents[1] / "sites.exs"
    try:
        process = subprocess.run(  # noqa: S603
            ["elixir", str(helper)],  # noqa: S607
            cwd=root,
            input=json.dumps({"source": data.decode("utf-8"), "line": line}),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise DxError("outgoing_parser", "Elixir call-site parser timed out") from error
    except OSError as error:
        raise DxError("outgoing_parser", str(error)) from error
    if process.returncode:
        raise DxError("outgoing_parser", process.stderr or process.stdout)
    try:
        parsed: JsonObject = json.loads(process.stdout)
    except ValueError as error:
        raise DxError("outgoing_parser", "Elixir call-site parser returned invalid JSON") from error
    return parsed


def outgoing_calls(
    session: Session,
    root: Path,
    path: Path,
    data: bytes,
    params: JsonObject,
    report: JsonObject,
) -> list[JsonObject]:
    parsed = parse_sites(root, data, params.get("line", 1), session.timeout)
    calls: dict[str, JsonObject] = {}
    unresolved = 0
    for site in parsed["sites"]:
        items = session.request(
            "textDocument/prepareCallHierarchy",
            {"textDocument": {"uri": path.as_uri()}, "position": site["range"]["start"]},
        )
        if not items:
            unresolved += 1
            continue
        item = items[0]
        # Keep distinct arities and anchors distinct; Dexter supplies the identity.
        key = json.dumps(item, sort_keys=True)
        calls.setdefault(key, {"to": item, "fromRanges": []})["fromRanges"].append(site["range"])
    report.update(caller=parsed["caller"], clauses=parsed["clauses"], unresolved_count=unresolved)
    return list(calls.values())
