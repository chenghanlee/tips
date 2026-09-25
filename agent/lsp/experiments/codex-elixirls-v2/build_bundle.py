#!/usr/bin/env python3
"""Build the pinned stack from source archives; installed output is relocatable.

Build prerequisites: macOS arm64, Elixir 1.20.4 / OTP 29.1, Python 3.14.3,
Rust 1.97.0, curl, git, patch and unbuffer. No prior experiment build is used.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
from collections.abc import Sequence
from pathlib import Path
from typing import IO, TypedDict, cast

HERE = Path(__file__).resolve().parent
VERSION_EXPRESSION = (
    'IO.write(System.version() <> "/" <> String.trim(File.read!(Path.join('
    '[:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"]))))'
)
ADAPTER_FILES = (
    "neovim_init.lua",
    "neovim_owner.lua",
    "neovim_sync.lua",
    "neovim_feedback.lua",
    "neovim_launcher.py",
    "neovim_hook.py",
    "neovim_prepare.py",
)
PROVENANCE_FILES = (
    "build_bundle.py",
    "bundle-lock.json",
    "mix-targeted-invalidation.patch",
    "elixirls-targeted-invalidation.patch",
    "elixirls-cached-prune.patch",
    "elixirls-dependency-reload.patch",
    "elixirls-open-document-version.patch",
    "elixirls-references-call-env.patch",
    "elixirls-workspace-symbols-full-index.patch",
    "elixir-sense-call-env.patch",
    "vv-mcp-feedback.patch",
    "vv-mcp-owner.patch",
    "vv-mcp-beta-operations.patch",
)
CRITICAL_GLOBS = (
    ("adapter", "*"),
    # Mix runs Hex and rebar3 from here; a missing file would be downloaded at run time.
    ("mix-home", "**/*"),
    ("toolchain/lib/mix/ebin", "*.beam"),
    ("server/lib", "**/*.beam"),
    ("server/lib", "**/*.app"),
    ("vendor/beixiyo-vv-mcp.nvim/lua", "**/*.lua"),
    ("vendor/beixiyo-vv-utils.nvim/lua", "**/*.lua"),
)

type Command = Sequence[str | Path]


class Download(TypedDict):
    url: str
    sha256: str


class Lock(TypedDict):
    downloads: dict[str, Download]


class Manifest(TypedDict):
    format: int
    elixir_otp: str
    python: str
    rust_build: str
    lock: Lock
    patches: dict[str, str]
    files: dict[str, str]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Build:
    """One fresh destination; every command is logged and must succeed."""

    def __init__(self, root: Path, cache: Path, lock: Lock, log: IO[str]) -> None:
        self.root, self.cache, self.lock, self.log = root, cache, lock, log
        self.sources, self.vendor = root / "sources", root / "vendor"
        self.bin = root / "toolchain/bin"
        self.env = os.environ | {
            "ERL_FLAGS": "+S 4:4",
            "MIX_ENV": "prod",
            "MIX_HOME": str(root / "mix-home"),
            "HEX_HOME": str(root / "hex-home"),
        }

    def tool(self, name: str) -> str:
        """Resolve a host prerequisite on the build PATH to an absolute path."""
        path = shutil.which(name, path=self.env["PATH"])
        if path is None:
            raise RuntimeError("Missing build prerequisite: " + name)
        return path

    def run(self, command: Command, cwd: Path | None = None) -> None:
        argv = [str(part) for part in command]
        print(" ".join(argv), flush=True)
        # Absolute resolved executables with fixed or lock-pinned arguments; no shell.
        result = subprocess.run(  # noqa: S603
            argv, cwd=cwd or self.root, env=self.env, stdout=self.log, stderr=subprocess.STDOUT
        )
        self.log.flush()
        if result.returncode:
            raise RuntimeError(
                f"Command failed ({result.returncode}); see {self.root / 'build.log'}"
            )

    def output(self, command: Command) -> str:
        # Absolute resolved executable with fixed arguments; no shell.
        return subprocess.check_output(  # noqa: S603
            [str(part) for part in command], env=self.env, text=True
        )

    def fetch(self, name: str) -> Path:
        item = self.lock["downloads"][name]
        path = self.cache / name
        if not path.exists():
            self.run([self.tool("curl"), "-fL", "--retry", "3", item["url"], "-o", path])
        if sha(path) != item["sha256"]:
            raise RuntimeError("Download checksum mismatch: " + name)
        return path

    def extract(self, name: str, dest: Path) -> None:
        with tarfile.open(self.fetch(name)) as archive:
            top = archive.getmembers()[0].name.split("/")[0]
            staging = self.root / ("extract-" + name)
            archive.extractall(staging, filter="data")
            shutil.move(staging / top, dest)
            staging.rmdir()

    def patch(self, name: str, cwd: Path) -> None:
        self.run([self.tool("patch"), "-p1", "-i", HERE / name], cwd)

    def mix(self, *arguments: str | Path, cwd: Path | None = None) -> None:
        self.run([self.tool("unbuffer"), self.bin / "mix", *arguments], cwd)

    def check_rust(self) -> str:
        rust = self.output([self.tool("rustc"), "--version"])
        if not rust.startswith("rustc 1.97.0 "):
            raise RuntimeError("Requires Rust 1.97.0")
        return rust.strip()

    def install_toolchain(self) -> str:
        shutil.copytree(Path(self.tool("elixir")).resolve().parent.parent, self.root / "toolchain")
        for beam in (self.root / "toolchain/lib/mix/ebin").glob("*.beam"):
            beam.chmod(beam.stat().st_mode | 0o200)
        # Mix and elixirc child processes find the private toolchain first.
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        version = self.output([self.bin / "elixir", "-e", VERSION_EXPRESSION])
        if version != "1.20.4/29.1":
            raise RuntimeError("Requires Elixir 1.20.4/OTP 29.1; found " + version)
        return version

    def patch_mix(self) -> None:
        names = ("compiler_elixir.ex", "compile_elixir_task.ex")
        self.sources.mkdir()
        for name in names:
            shutil.copy2(self.fetch(name), self.sources / name)
        self.patch("mix-targeted-invalidation.patch", self.sources)
        for name in names:
            self.run(
                [
                    self.bin / "elixirc",
                    "--ignore-module-conflict",
                    "--warnings-as-errors",
                    "-o",
                    self.root / "toolchain/lib/mix/ebin",
                    self.sources / name,
                ]
            )

    def install_hex(self) -> None:
        hex_source = self.sources / "hex"
        self.extract("hex-source.tar.gz", hex_source)
        self.mix("archive.build", cwd=hex_source)
        self.mix("archive.install", hex_source / "hex-2.5.1.ez", "--force")

    def install_rebar3(self) -> None:
        """Mix's own install path, from the pinned download; never fetched at run time."""
        self.mix("local.rebar", "rebar3", self.fetch("rebar3-3.25.1-otp-28"), "--force")

    def build_server(self) -> None:
        elixirls = self.sources / "elixirls"
        self.extract("elixirls.tar.gz", elixirls)
        self.patch("elixirls-targeted-invalidation.patch", elixirls)
        self.patch("elixirls-cached-prune.patch", elixirls)
        self.patch("elixirls-dependency-reload.patch", elixirls)
        self.patch("elixirls-open-document-version.patch", elixirls)
        self.patch("elixirls-references-call-env.patch", elixirls)
        self.patch("elixirls-workspace-symbols-full-index.patch", elixirls)
        self.mix("deps.get", "--check-locked", cwd=elixirls)
        # elixir_sense is a git dependency, present only after deps.get
        self.patch("elixir-sense-call-env.patch", elixirls / "deps/elixir_sense")
        # Dependency warnings never fail the umbrella build, so a call site the patch missed would
        # only warn here and crash parses at run time. Compile the patched library strictly first.
        self.mix("compile", "--force", "--warnings-as-errors", cwd=elixirls / "deps/elixir_sense")
        self.mix("compile", cwd=elixirls)
        (self.root / "server/lib").mkdir(parents=True)
        for app in (elixirls / "_build/shared/lib").iterdir():
            if (app / "ebin").is_dir():
                for part in ("ebin", "priv"):
                    if (app / part).exists():
                        shutil.copytree(app / part, self.root / "server/lib" / app.name / part)

    def build_vendor(self) -> None:
        plugin = self.vendor / "beixiyo-vv-mcp.nvim"
        self.vendor.mkdir()
        self.extract("nvim.tar.gz", self.vendor / "nvim-macos-arm64")
        self.extract("vv-mcp.tar.gz", plugin)
        self.extract("vv-utils.tar.gz", self.vendor / "beixiyo-vv-utils.nvim")
        for name in (
            "vv-mcp-feedback.patch",
            "vv-mcp-owner.patch",
            "vv-mcp-beta-operations.patch",
        ):
            self.patch(name, plugin)
        self.run([self.tool("cargo"), "build", "--release", "--locked", "-p", "vv-mcp"], plugin)
        shutil.copy2(plugin / "target/release/vv-mcp", self.vendor / "vv-mcp")
        wheels = [self.fetch(name) for name in self.lock["downloads"] if name.endswith(".whl")]
        self.run(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--no-deps",
                "--no-index",
                "--target",
                self.vendor / "python",
                *wheels,
            ]
        )

    def install_entry_points(self) -> Path:
        (self.root / "adapter").mkdir()
        for name in ADAPTER_FILES:
            shutil.copy2(HERE / name, self.root / "adapter" / name)
        shutil.copy2(HERE / "bundle.py", self.root / "bundle.py")
        # bundle.py serve passes its verified interpreter; PATH may name another Python.
        launcher = self.root / "elixir-ls"
        launcher.write_text(
            "#!/bin/sh\n"
            'exec "${V2_PYTHON:?set by bundle.py serve}" "$(dirname "$0")/bundle.py" server\n'
        )
        launcher.chmod(0o755)
        for name in PROVENANCE_FILES:
            shutil.copy2(HERE / name, self.root / name)
        # Keep provenance sources but discard build-only Rust output and dependency Git data.
        shutil.rmtree(self.vendor / "beixiyo-vv-mcp.nvim/target")
        return launcher

    def write_manifest(self, version: str, rust: str, launcher: Path) -> None:
        critical = [
            self.root / "bundle.py",
            # The recipe that built this bundle: patch order and build-time checks.
            self.root / "build_bundle.py",
            launcher,
            self.vendor / "vv-mcp",
            self.vendor / "nvim-macos-arm64/bin/nvim",
        ]
        for directory, pattern in CRITICAL_GLOBS:
            critical += [p for p in (self.root / directory).glob(pattern) if p.is_file()]
        manifest: Manifest = {
            "format": 1,
            "elixir_otp": version,
            "python": platform.python_version(),
            "rust_build": rust,
            "lock": self.lock,
            "patches": {p.name: sha(p) for p in self.root.glob("*.patch")},
            "files": {str(p.relative_to(self.root)): sha(p) for p in critical},
        }
        (self.root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    root = cast(Path, args.destination).resolve()
    cache = cast(Path, args.cache).resolve()
    if root.exists():
        parser.error("Destination already exists; use a fresh destination")
    host = (platform.system(), platform.machine(), platform.python_version())
    if host != ("Darwin", "arm64", "3.14.3"):
        parser.error("Requires macOS arm64 and Python 3.14.3")
    lock = cast(Lock, json.loads((HERE / "bundle-lock.json").read_text()))
    root.mkdir(parents=True)
    cache.mkdir(parents=True, exist_ok=True)
    with (root / "build.log").open("w") as log:
        build = Build(root, cache, lock, log)
        rust = build.check_rust()
        version = build.install_toolchain()
        build.patch_mix()
        build.install_hex()
        build.install_rebar3()
        build.build_server()
        build.build_vendor()
        launcher = build.install_entry_points()
        build.write_manifest(version, rust, launcher)
        build.run([sys.executable, root / "bundle.py", "doctor"])
    print("Built and verified " + str(root), flush=True)


if __name__ == "__main__":
    main()
