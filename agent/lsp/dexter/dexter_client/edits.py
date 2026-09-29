"""Edit-target boundaries, UTF-16 coordinates, and workspace-edit application."""

import hashlib
import os
import re
import tempfile
from collections.abc import Sequence
from pathlib import Path
from urllib.parse import unquote, urlparse

from .protocol import DxError, JsonObject

type Snapshot = dict[Path, bytes]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def bound_path(root: Path, name: str | Path) -> Path:
    path = (root / name).resolve()
    if not path.is_relative_to(root) or path == root:
        raise DxError("scope", "File must be inside the bound worktree")
    rel = path.relative_to(root)
    if any(p in {".git", ".dexter", "_build", "deps", ".worktrees"} for p in rel.parts):
        raise DxError(
            "scope", "Generated, dependency, nested-worktree and Git files are not writable inputs"
        )
    # Refuse files in a nested checkout even if lexically under the bound root.
    for parent in path.parents:
        if parent == root:
            break
        if (parent / ".git").exists() or (parent / ".dexter/dexter.db").exists():
            raise DxError("scope", "File belongs to a nested worktree")
    return path


def uri_path(root: Path, uri: str) -> Path:
    parsed = urlparse(uri)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        raise DxError("edit", "Only local file URIs are supported")
    return bound_path(root, unquote(parsed.path))


def offset(text: str, position: dict[str, int]) -> int:
    """Convert an LSP UTF-16 position to a Python string index; never round."""
    line, char = position["line"], position["character"]
    parts = re.split(r"(\r\n|\r|\n)", text)
    lines = parts[::2]
    if line < 0 or char < 0 or line >= len(lines):
        raise DxError("position", position)
    prefix = sum(len(s) for s in parts[: 2 * line])
    content = lines[line]
    units = 0
    for i, value in enumerate(content):
        if units == char:
            return prefix + i
        units += len(value.encode("utf-16-le")) // 2
    if units == char:
        return prefix + len(content)
    raise DxError("position", "Column is beyond the line or splits a surrogate pair")


def edit_text(text: str, edits: Sequence[JsonObject]) -> str:
    spans = [
        (offset(text, e["range"]["start"]), offset(text, e["range"]["end"]), e["newText"])
        for e in edits
    ]
    spans.sort(key=lambda s: (s[0], s[1]))
    end = -1
    for start, stop, _ in spans:
        if stop < start or start < end:
            raise DxError("edit", "Invalid or overlapping text edits")
        end = stop
    for start, stop, replacement in reversed(spans):
        text = text[:start] + replacement + text[stop:]
    return text


def plan_resource(root: Path, change: JsonObject, plan: Snapshot, touched: set[Path]) -> None:
    kind = change["kind"]
    path = uri_path(root, change["oldUri"] if kind == "rename" else change["uri"])
    if kind == "create":
        if path in plan or path.exists():
            raise DxError("edit", "Refusing to overwrite an existing resource")
        plan[path] = b""
    elif kind == "delete":
        if path not in plan:
            raise DxError("edit", "Delete target was not captured in the source snapshot")
        del plan[path]
    else:
        target = uri_path(root, change["newUri"])
        if path not in plan or target in plan or target.exists():
            raise DxError("edit", "Rename source missing or target already exists")
        plan[target] = plan.pop(path)
        touched.add(target)
    touched.add(path)


def plan_document(root: Path, change: JsonObject, plan: Snapshot, touched: set[Path]) -> None:
    if "textDocument" not in change:
        raise DxError("edit", {"unsupported_change": change})
    path = uri_path(root, change["textDocument"]["uri"])
    if path not in plan:
        raise DxError("edit", "Edit target was not captured in the source snapshot")
    if change["textDocument"].get("version") not in (None, 1):
        raise DxError("edit", "Unexpected document version")
    plan[path] = edit_text(plan[path].decode("utf-8"), change["edits"]).encode("utf-8")
    touched.add(path)


def write_planned_file(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Coordinates cooperating writers only; the final check/replace is not CAS.
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=".dx-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_workspace_edit(root: Path, edit: JsonObject, baseline: Snapshot) -> list[str]:
    """Validate the entire proposal first, then write. Not a multi-file transaction."""
    if edit.get("changeAnnotations"):
        raise DxError("edit", "Annotated edits need an explicit confirmation workflow")
    changes: list[JsonObject] = [
        {"textDocument": {"uri": uri}, "edits": edits}
        for uri, edits in edit.get("changes", {}).items()
    ]
    changes.extend(edit.get("documentChanges", []))
    plan = dict(baseline)
    touched: set[Path] = set()
    for change in changes:
        if change.get("kind") in ("create", "rename", "delete"):
            plan_resource(root, change, plan, touched)
        else:
            plan_document(root, change, plan, touched)
    for path in touched:
        current = path.read_bytes() if path.exists() else None
        if current != baseline.get(path):
            raise DxError("changed_base", str(path))
    for path in sorted(touched):
        if path not in plan:
            path.unlink()
        else:
            write_planned_file(path, plan[path])
    return [str(p.relative_to(root)) for p in sorted(touched)]
