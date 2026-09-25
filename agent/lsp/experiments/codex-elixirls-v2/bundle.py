#!/usr/bin/env python3
"""Installed stack entry point. No experiment or download directory is consulted."""

import argparse
import hashlib
import json
import os
import platform
import selectors
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import IO, TypedDict, cast

ROOT = Path(__file__).resolve().parent
HOOK_MATCHER = "^(apply_patch|Bash)$"


class Manifest(TypedDict):
    python: str
    elixir_otp: str
    files: dict[str, str]


class ListedHook(TypedDict, total=False):
    """The `hooks/list` fields that decide whether Codex runs a hook."""

    eventName: str
    command: str
    matcher: str | None
    enabled: bool
    trustStatus: str


class ListedCwd(TypedDict):
    hooks: list[ListedHook]


class Arguments(argparse.Namespace):
    mode: str
    workspace: Path | None
    state: Path | None
    lsp_approval_mode: str
    force: bool


def configuration(workspace: Path, approval: str = "prompt") -> dict[str, str]:
    """One configuration generator for team provisioning and standalone beta use."""
    workspace = workspace.resolve()
    arguments = ["--workspace", str(workspace), "--state", str(workspace / ".elixir_ls/session")]
    config = f"""[plugins."mix-compile@elixir-agent-tools"]
enabled = false
[plugins."mix-credo@elixir-agent-tools"]
enabled = true

[mcp_servers.elixir-lsp]
command = "/usr/bin/false"
enabled = false

[mcp_servers.elixir_neovim]
command = {json.dumps(sys.executable)}
args = {json.dumps([str(ROOT / "bundle.py"), "serve", *arguments])}
cwd = {json.dumps(str(workspace))}
enabled_tools = ["lsp"]
required = true
tool_timeout_sec = 120

[mcp_servers.elixir_neovim.tools.lsp]
approval_mode = {json.dumps(approval)}
"""
    return {".codex/config.toml": config}


def hook_command() -> str:
    # Codex runs hooks in its session cwd. Keep the definition identical across
    # worktrees so reviewing another worktree does not replace its trusted hash.
    return (
        shlex.join([sys.executable, str(ROOT / "bundle.py"), "hook"])
        + ' --workspace "$PWD" --state "$PWD/.elixir_ls/session" --budget-ms 5000'
    )


def codex_arguments(workspace: Path) -> list[str]:
    """Linked worktrees inherit main-repo hooks; attach beta hooks to this session."""
    handler = (
        '{type = "command", command = '
        + json.dumps(hook_command())
        + ', timeout = 6, statusMessage = "Reading ElixirLS compiler feedback"}'
    )
    return [
        "-C",
        str(workspace.resolve()),
        "-c",
        "hooks.PostToolUse = [{matcher = "
        + json.dumps(HOOK_MATCHER)
        + ", hooks = ["
        + handler
        + "]}]",
        "-c",
        "hooks.Stop = [{hooks = [" + handler + "]}]",
    ]


def list_hooks(workspace: Path) -> list[ListedHook]:
    """Ask Codex which hooks this launch loads and whether it trusts them."""
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("Codex is not on PATH")
    # Resolved client, the launch's own session flags and the read-only hooks/list method.
    with (
        subprocess.Popen(  # noqa: S603
            [executable, "app-server", "--stdio", *codex_arguments(workspace)[2:]],
            cwd=workspace,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ) as server
    ):
        requests, replies = cast(IO[str], server.stdin), cast(IO[str], server.stdout)
        selector = selectors.DefaultSelector()
        selector.register(replies, selectors.EVENT_READ)
        deadline = time.monotonic() + 30

        def request(number: int, method: str, params: object) -> dict[str, object]:
            requests.write(json.dumps({"id": number, "method": method, "params": params}) + "\n")
            requests.flush()
            # Codex exits at end of input, so wait for each answer before closing.
            while selector.select(max(0.0, deadline - time.monotonic())):
                line = replies.readline()
                if not line:
                    break
                reply = cast(dict[str, object], json.loads(line))
                if reply.get("id") == number and "result" in reply:
                    return cast(dict[str, object], reply["result"])
                if reply.get("id") == number:
                    raise RuntimeError(f"Codex rejected {method}: {reply.get('error')}")
            raise RuntimeError(f"Codex did not answer {method} within 30 seconds")

        request(1, "initialize", {"clientInfo": {"name": "elixirls-hook-check", "version": "1"}})
        requests.write('{"method": "initialized"}\n')
        listed = cast(list[ListedCwd], request(2, "hooks/list", {"cwds": [str(workspace)]})["data"])
    return [hook for entry in listed for hook in entry["hooks"]]


def verify_hooks(workspace: Path) -> list[dict[str, object]]:
    """Admission check: Codex runs this bundle's two hooks only when both are trusted."""
    command = hook_command()
    ours = [
        hook
        for hook in list_hooks(workspace.resolve(strict=True))
        if hook.get("command") == command
    ]
    found: list[dict[str, object]] = [
        {
            "event": hook.get("eventName"),
            "matcher": hook.get("matcher"),
            "enabled": hook.get("enabled"),
            "trust": hook.get("trustStatus"),
        }
        for hook in sorted(ours, key=lambda hook: str(hook.get("eventName")))
    ]
    expected: list[dict[str, object]] = [
        {"event": "postToolUse", "matcher": HOOK_MATCHER, "enabled": True, "trust": "trusted"},
        {"event": "stop", "matcher": None, "enabled": True, "trust": "trusted"},
    ]
    if found != expected:
        raise RuntimeError(
            "Beta hooks are not ready: "
            + json.dumps(found)
            + ". Review both in Codex /hooks; untrusted or modified hooks do not run."
        )
    return found


def configure(workspace: Path, approval: str, force: bool) -> None:
    workspace = workspace.resolve(strict=True)
    if not (workspace / "mix.exs").is_file():
        raise ValueError("Workspace must contain mix.exs")
    files = {
        workspace / name: content for name, content in configuration(workspace, approval).items()
    }
    for path, content in files.items():
        if path.is_symlink() or path.parent.is_symlink():
            raise ValueError("Refusing symlinked client configuration: " + str(path))
        if path.exists() and path.read_text() != content and not force:
            raise ValueError("Configuration differs; inspect it before using --force: " + str(path))
    for path, content in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.read_text() == content:
            continue
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        try:
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    print(
        "Configured Neovim beta in "
        + str(workspace)
        + ". Start with bundle.py codex; review its session hooks with /hooks."
    )


def verify() -> Manifest:
    manifest = cast(Manifest, json.loads((ROOT / "manifest.json").read_text()))
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("This bundle supports macOS arm64 only")
    if platform.python_version() != manifest["python"]:
        raise RuntimeError("Python version differs from the bundle: " + manifest["python"])
    for name, expected in manifest["files"].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("Bundle integrity mismatch: " + name)
    # Fixed bundled executable and expression; paths are argv entries, never shell input.
    version = subprocess.check_output(  # noqa: S603
        [
            str(ROOT / "toolchain/bin/elixir"),
            "-e",
            'IO.write(System.version() <> "/" <> String.trim(File.read!(Path.join('
            '[:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]))))',
        ],
        env=os.environ | {"ERL_FLAGS": "+S 2:2"},
        text=True,
    )
    if version != manifest["elixir_otp"]:
        raise RuntimeError("Elixir/OTP mismatch: " + version)
    return manifest


def prepare(workspace: Path, state: Path) -> Path:
    workspace, state = workspace.resolve(strict=True), state.resolve()
    if not (workspace / "mix.exs").is_file():
        raise ValueError("Workspace must contain mix.exs")
    config = state / "config/nvim"
    (config / "lua").mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "adapter/neovim_init.lua", config / "init.lua")
    for name in ("neovim_owner.lua", "neovim_sync.lua", "neovim_feedback.lua"):
        shutil.copy2(ROOT / "adapter" / name, config / "lua" / name)
    # Only called with exclusive session ownership in the supported entry points.
    # A killed Neovim cannot unregister itself; none of these old entries is live.
    for path in (state / "registry").glob("*.json"):
        path.unlink()
    (state / "feedback-unavailable").unlink(missing_ok=True)
    env = {
        f"XDG_{kind.upper()}_HOME": str(state / kind)
        for kind in ("config", "data", "state", "cache")
    }
    env.update(
        {
            "PATH": str(ROOT / "toolchain/bin")
            + os.pathsep
            + str(ROOT / "vendor/nvim-macos-arm64/bin")
            + os.pathsep
            + os.environ["PATH"],
            "NVIM_LOG_FILE": str(state / "nvim.log"),
            "VV_MCP_REGISTRY": str(state / "registry"),
            "V2_VV_PLUGIN": str(ROOT / "vendor/beixiyo-vv-mcp.nvim"),
            "V2_VV_UTILS": str(ROOT / "vendor/beixiyo-vv-utils.nvim"),
            "V2_VV_BINARY": str(ROOT / "vendor/vv-mcp"),
            "V2_ELIXIR_LS": str(ROOT / "elixir-ls"),
            # The server entry runs the interpreter verify() checked, not PATH python3.
            "V2_PYTHON": sys.executable,
            "V2_WORKSPACE": str(workspace),
            "V2_SESSION_STATE": str(state),
            "VV_MCP_MANAGED_IDLE_TIMEOUT_MS": "300000",
            "V2_SYNC_READS": "1",
            "V2_FEEDBACK": "1",
            "V2_AUTOMATIC": "1",
            "ERL_FLAGS": "+S 4:4",
        }
    )
    path = state / "environment.json"
    path.write_text(json.dumps(env, indent=2) + "\n")
    return path


def server() -> None:
    # Upstream main owns protocol, logging, Mix and application startup.
    # All library directories are private, precompiled and relocated together.
    env = os.environ | {"MIX_HOME": str(ROOT / "mix-home"), "ELS_MODE": "language_server"}
    command = [str(ROOT / "toolchain/bin/elixir")]
    for ebin in sorted((ROOT / "server/lib").glob("*/ebin")):
        command += ["-pa", str(ebin)]
    command += [
        "-e",
        "Application.put_env(:elixir, :ansi_enabled, false); ElixirLS.LanguageServer.main()",
    ]
    sys.path.insert(0, str(ROOT / "adapter"))
    from neovim_launcher import locks, server_lock_paths

    workspace = Path(os.environ.get("V2_WORKSPACE", os.getcwd())).resolve()
    state = Path(os.environ.get("V2_SESSION_STATE", str(workspace / ".elixir_ls/session")))
    with locks(server_lock_paths(workspace, state.resolve())) as descriptors:
        for descriptor in descriptors:
            os.set_inheritable(descriptor, True)
        # Fixed bundled server; exec preserves the compiler's lifetime locks.
        os.execve(command[0], command, env)  # noqa: S606


def start_codex(workspace: Path, extra: list[str]) -> None:
    workspace = workspace.resolve(strict=True)
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("Codex is not on PATH")
    if extra[:1] == ["--"]:
        extra = extra[1:]
    os.chdir(workspace)
    # exec discards Python's buffers: a piped stdout would lose the setup output.
    sys.stdout.flush()
    # Resolved client executable and argument array; no shell or trust bypass.
    os.execv(executable, [executable, *codex_arguments(workspace), *extra])  # noqa: S606


def client_setup(workspace: Path, args: Arguments, extra: list[str]) -> None:
    if args.mode == "config":
        print(json.dumps(configuration(workspace, args.lsp_approval_mode)))
    elif args.mode == "codex-args":
        print(json.dumps(codex_arguments(workspace)))
    elif args.mode == "verify-hooks":
        print(json.dumps(verify_hooks(workspace), indent=2))
    else:
        manifest = verify()
        sys.path.insert(0, str(ROOT / "adapter"))
        import neovim_prepare
        from neovim_launcher import ownership

        with ownership(workspace, workspace / ".elixir_ls/session"):
            if args.mode != "prepare-deps":
                configure(workspace, args.lsp_approval_mode, args.force)
            if args.mode != "configure":
                # About a minute on a new worktree; ElixirLS then reuses these dependencies.
                print(json.dumps(neovim_prepare.prepare(workspace, ROOT, manifest["elixir_otp"])))
        if args.mode == "codex":
            start_codex(workspace, extra)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        choices=[
            "doctor",
            "config",
            "configure",
            "codex-args",
            "codex",
            "verify-hooks",
            "prepare-deps",
            "prepare",
            "serve",
            "hook",
            "server",
        ],
    )
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument(
        "--lsp-approval-mode", choices=["auto", "prompt", "writes", "approve"], default="prompt"
    )
    parser.add_argument("--force", action="store_true")
    args, extra = parser.parse_known_args(namespace=Arguments())
    if args.mode in {"config", "configure", "codex-args", "codex", "verify-hooks", "prepare-deps"}:
        if not args.workspace:
            parser.error("--workspace is required")
        client_setup(args.workspace, args, extra)
    elif args.mode == "doctor":
        print(json.dumps(verify(), indent=2))
    elif args.mode == "server":
        server()
    else:
        if not args.workspace or not args.state:
            parser.error("--workspace and --state are required")
        if args.mode == "prepare":
            verify()
            sys.path.insert(0, str(ROOT / "adapter"))
            from neovim_launcher import ownership

            with ownership(args.workspace, args.state):
                print(prepare(args.workspace, args.state))
        elif args.mode == "serve":
            verify()
            sys.path.insert(0, str(ROOT / "adapter"))
            from neovim_launcher import launch, ownership

            with ownership(args.workspace, args.state) as lock_fds:
                path = prepare(args.workspace, args.state)
                launch(ROOT / "vendor", args.workspace.resolve(), path, lock_fds)
        else:
            # Current Python and bundled hook; caller options remain separate arguments.
            os.execv(  # noqa: S606
                sys.executable,
                [
                    sys.executable,
                    str(ROOT / "adapter/neovim_hook.py"),
                    "--vendor",
                    str(ROOT / "vendor"),
                    "--workspace",
                    str(args.workspace.resolve()),
                    "--registry",
                    str(args.state.resolve() / "registry"),
                    *extra,
                ],
            )


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print(f"ElixirLS session: {error}", file=sys.stderr)
        raise SystemExit(1) from error
