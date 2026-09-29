"""Named language operations and their LSP request sequences."""

from collections.abc import Sequence
from pathlib import Path
from typing import Any, cast

from .edits import Snapshot, apply_workspace_edit, bound_path, digest, offset
from .incoming import incoming_calls
from .protocol import DxError, JsonObject, Session

METHODS = {
    "definition": "textDocument/definition",
    "type-definition": "textDocument/typeDefinition",
    "declaration": "textDocument/declaration",
    "implementation": "textDocument/implementation",
    "references": "textDocument/references",
    "hover": "textDocument/hover",
    "highlights": "textDocument/documentHighlight",
    "symbols": "textDocument/documentSymbol",
    "workspace-symbols": "workspace/symbol",
    "signature": "textDocument/signatureHelp",
    "completion": "textDocument/completion",
    "folding": "textDocument/foldingRange",
    "code-actions": "textDocument/codeAction",
    "format": "textDocument/formatting",
    "prepare-rename": "textDocument/prepareRename",
    "rename": "textDocument/rename",
    "call-hierarchy": "textDocument/prepareCallHierarchy",
    "incoming-calls": "callHierarchy/incomingCalls",
    "outgoing-calls": "callHierarchy/outgoingCalls",
}


def selected(items: Sequence[JsonObject], params: JsonObject) -> JsonObject:
    if not items:
        raise DxError("selection", "No candidate returned; this does not establish index freshness")
    index = params.get("select", 0)
    if isinstance(index, str):
        matches = [item for item in items if item.get("label", item.get("title")) == index]
        if len(matches) != 1:
            raise DxError("selection", "Label/title must match exactly one candidate")
        return matches[0]
    if not isinstance(index, int) or not 0 <= index < len(items):
        raise DxError("selection", "select must name a returned candidate index")
    return items[index]


def document_request(
    session: Session, path: Path, data: bytes, op: str, params: JsonObject
) -> JsonObject:
    position = {"line": params.get("line", 1) - 1, "character": params.get("column", 1) - 1}
    offset(data.decode(), position)
    request: JsonObject = {"textDocument": {"uri": path.as_uri()}, "position": position}
    if op == "references":
        request["context"] = {"includeDeclaration": params.get("include_declaration", True)}
    if op == "rename":
        if params.get("apply") is not True:
            raise DxError("mutation", "Rename can write inside Dexter; explicitly set apply=true")
        request["newName"] = params["new_name"]
    if op in ("format", "diagnostics"):
        session.open(path, data.decode())
        request["options"] = params.get("options", {"tabSize": 2, "insertSpaces": True})
    if op == "code-actions":
        request["range"] = params.get("range", {"start": position, "end": position})
        request["context"] = {"diagnostics": params.get("diagnostics", [])}
    return request


def query_document(
    session: Session,
    root: Path,
    path: Path,
    op: str,
    params: JsonObject,
    request: JsonObject,
    report: JsonObject,
) -> Any:
    if op == "diagnostics":
        session.request("textDocument/formatting", request)
        report["diagnostic_kind"] = "syntax"
        return session.diagnostics(path.as_uri())
    if op in ("incoming-calls", "outgoing-calls"):
        items = session.request("textDocument/prepareCallHierarchy", request)
        report["prepared_items"] = items
        if op == "incoming-calls":
            return incoming_calls(session, root, selected(items or [], params), report)
        report["followup_sent"] = bool(items)
        if not items:
            return None
        request = {"item": selected(items, params)}
    result = session.request(METHODS[op], request)
    if op == "format":
        diagnostics = session.diagnostics(path.as_uri())
        report["syntax_diagnostics"] = diagnostics
        if any(d.get("severity") == 1 for d in diagnostics["diagnostics"]):
            raise DxError("formatter", diagnostics)
    return result


def completion_edit(item: JsonObject, params: JsonObject) -> JsonObject:
    if item.get("command"):
        raise DxError("completion", "Completion commands are not advertised by pinned Dexter")
    if item.get("insertTextFormat", 1) == 2 and "insert_text" not in params:
        raise DxError("completion", "Supply insert_text with the filled-in plain text to apply it")
    edit: JsonObject | None = item.get("textEdit")
    if edit and "range" not in edit:
        edit = {"range": edit["replace"], "newText": edit["newText"]}
    if not edit:
        if "replace_range" not in params:
            raise DxError(
                "completion", "This item needs an explicit zero-based UTF-16 replace_range"
            )
        edit = {"range": params["replace_range"], "newText": item.get("insertText", item["label"])}
    if "insert_text" in params:
        edit = {**edit, "newText": params["insert_text"]}
    return edit


def resolve_completion(
    session: Session,
    root: Path,
    path: Path,
    result: Any,
    params: JsonObject,
    report: JsonObject,
    before: Snapshot,
) -> None:
    items = cast(
        Sequence[JsonObject],
        cast(JsonObject, result).get("items", []) if isinstance(result, dict) else result,
    )
    item = session.request("completionItem/resolve", selected(items, params))
    report["resolved_item"] = item
    if params.get("apply"):
        edits = [completion_edit(item, params), *item.get("additionalTextEdits", [])]
        report["applied"] = apply_workspace_edit(root, {"changes": {path.as_uri(): edits}}, before)


def apply_result(
    root: Path,
    path: Path,
    op: str,
    result: Any,
    params: JsonObject,
    report: JsonObject,
    before: Snapshot,
) -> None:
    edit: JsonObject = result
    if op == "format":
        edit = {"changes": {path.as_uri(): result or []}}
    elif op == "code-actions":
        action = selected(result, params)
        report["selected_action"] = action
        if action.get("command") or action.get("disabled"):
            raise DxError("code_action", "Command/disabled actions are not supported")
        edit = action.get("edit", {})
    # Server-side rename may already have written; validate returned edits against
    # the original snapshot, never against a newer (possibly overwritten) base.
    report["applied"] = apply_workspace_edit(root, edit or {}, before)


def workflow(
    session: Session, root: Path, op: str, params: JsonObject, report: JsonObject, before: Snapshot
) -> Any:
    if op == "workspace-symbols":
        return session.request(METHODS[op], {"query": params.get("query", "")})
    path = bound_path(root, params["file"])
    data = path.read_bytes()
    report["source"] = {"uri": path.as_uri(), "sha256": digest(data)}
    if params.get("expected_sha256", digest(data)) != digest(data):
        raise DxError("changed_base", "Input position refers to a different file revision")
    request = document_request(session, path, data, op, params)
    result = query_document(session, root, path, op, params, request, report)
    if op == "completion" and ("select" in params or params.get("apply")):
        resolve_completion(session, root, path, result, params, report, before)
    if params.get("apply") and op in ("format", "code-actions", "rename"):
        apply_result(root, path, op, result, params, report, before)
    if not params.get("apply") and path.read_bytes() != data:
        raise DxError("changed_base", "Source changed during the lookup; result rejected")
    if op == "incoming-calls" and result["unavailable"]:
        report["result"] = result
        raise DxError(
            "incoming_unavailable",
            f"{len(result['unavailable'])} reference line(s) have no supported source owner",
        )
    return result
