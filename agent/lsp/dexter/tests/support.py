"""Shared assertions for the standard-library test runner."""

from collections.abc import Callable

from agent.lsp.dexter.dexter_client.protocol import DxError


def dx_error(call: Callable[[], object]) -> DxError:
    try:
        call()
    except DxError as error:
        return error
    raise AssertionError("Expected DxError")
