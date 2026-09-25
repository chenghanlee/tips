"""Seeding boundaries on real directory trees, links and subprocesses."""

import gzip
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import neovim_prepare

FILES = {
    "mix.exs": "",
    "deps/alpha/priv/data.txt": "data",
    "deps/alpha/include/alpha.hrl": "-define(ALPHA, 1).",
    "deps/alpha/src/alpha.erl": "-module(alpha).",
    "deps/beta/lib/beta.ex": "defmodule Beta do end",
    "_build/test/lib/alpha/ebin/alpha.app": "{application,alpha,[]}.",
    "_build/test/lib/beta/ebin/beta.app": "{application,beta,[]}.",
    "_build/test/lib/tips/ebin/tips.app": "{application,tips,[]}.",
}


def links(root: Path) -> dict[Path, Path]:
    """Every link below root, keyed by its path relative to root."""
    return {path.relative_to(root): path for path in root.rglob("*") if path.is_symlink()}


def tools(root: Path, compile_exit: int = 0, version: str = "1.20.4/29") -> Path:
    """Fake project Mix/Elixir that record what they were asked to do."""
    tools = root / "bin"
    tools.mkdir()
    log = shlex.quote(str(root / "mix.log"))
    (tools / "mix").write_text(
        f'#!/bin/sh\necho "$MIX_ENV $*" >> {log}\n'
        # Mix's install prompts read stdin; report what a prompt would receive.
        'read answer || answer=none\necho "mix $1 answer=$answer"\n'
        f'[ "$1" = deps.compile ] && exit {compile_exit}\nexit 0\n'
    )
    (tools / "elixir").write_text(f"#!/bin/sh\nprintf %s {version}\n")
    for tool in tools.iterdir():
        tool.chmod(0o755)
    return tools / "mix"


class SeedTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="tips prepare ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.workspace = self.root / "work tree"
        for name, text in FILES.items():
            (self.workspace / name).parent.mkdir(parents=True, exist_ok=True)
            (self.workspace / name).write_text(text)
        built = self.workspace / "_build/test/lib/alpha"
        # The link shapes Mix creates: priv/include for all, src for rebar3 deps.
        for name in ("priv", "include", "src"):
            (built / name).symlink_to("../../../../deps/alpha/" + name)
        (built / "ebin/alias.app").symlink_to("alpha.app")
        for app in ("alpha", "beta"):
            self.compiled(app, self.workspace / "deps" / app / "lib" / (app + ".ex"))
        # Mix's Erlang compiler lists outputs by absolute path; its version marker does not.
        (built / ".mix").mkdir()
        (built / ".mix/compile.erlang").write_text(str(built / "ebin/alpha_shims.beam"))
        (built / ".mix/compile.elixir_scm").write_text("1.20.4")
        self.lib = self.workspace / ".elixir_ls/build/test/lib"

    def compiled(self, app: str, source: Path, name: str = "", *, compress: bool = False) -> None:
        """A BEAM stand-in: compile info stores the absolute source path as bytes."""
        beam = self.workspace / f"_build/test/lib/{app}/ebin/Elixir.{name or app}.beam"
        data = b"FOR1\x00\x00\x00\x00BEAMCInf" + str(source).encode()
        beam.write_bytes(gzip.compress(data) if compress else data)

    def published(self) -> list[str]:
        return sorted(path.name for path in self.lib.iterdir())

    def prepare(self, mix: Path | None = None) -> neovim_prepare.Report:
        """prepare() with only the fake project toolchain, or no Mix, on PATH."""
        path = mix.parent if mix else self.root / "no-tools"
        with mock.patch.dict(os.environ, {"PATH": str(path)}):
            return neovim_prepare.prepare(self.workspace, self.root / "bundle", "1.20.4/29.1")

    def test_copies_dependencies_only_with_links_resolving_from_the_deeper_build(self) -> None:
        result = neovim_prepare.seed(self.workspace)
        assert (result["status"], result["seeded"]) == ("seeded", ["alpha", "beta"])
        assert self.published() == ["alpha", "beta"]
        assert os.readlink(self.lib / "alpha/priv") == "../../../../../deps/alpha/priv"
        assert (self.lib / "alpha/priv/data.txt").read_text() == "data"
        source = self.workspace / "_build/test/lib/alpha"
        published = links(self.lib / "alpha")
        assert set(published) == set(links(source))
        assert len(published) == 4
        for relative, link in published.items():
            # Same real target, except a link inside the copy stays inside it.
            target = Path(os.path.realpath(source / relative))
            if target.is_relative_to(source):
                target = self.lib / "alpha" / target.relative_to(source)
            assert link.exists(), relative
            assert Path(os.path.realpath(link)) == target, relative
        assert os.readlink(self.lib / "alpha/ebin/alias.app") == "alpha.app"
        assert (self.workspace / ".elixir_ls/.gitignore").read_text() == "*"
        # A later compile in the ElixirLS build must not delete normal-build outputs.
        assert sorted(p.name for p in (self.lib / "alpha/.mix").iterdir()) == ["compile.elixir_scm"]
        # The unadjusted copy used by the earlier experiment breaks at this depth.
        naive = self.workspace / ".elixir_ls/build/naive/lib/alpha"
        shutil.copytree(self.workspace / "_build/test/lib/alpha", naive, symlinks=True)
        assert not (naive / "priv").exists()

    def test_existing_build_directory_is_never_replaced(self) -> None:
        (self.lib / "alpha").mkdir(parents=True)
        (self.lib / "alpha/elixir-ls-output").write_text("")
        result = neovim_prepare.seed(self.workspace)
        assert (result["seeded"], result["skipped"]) == (["beta"], {"alpha": "present"})
        assert [path.name for path in (self.lib / "alpha").iterdir()] == ["elixir-ls-output"]

    def test_source_changed_during_copy_publishes_nothing(self) -> None:
        source = self.workspace / "_build/test/lib/alpha/ebin/alpha.app"

        def recompiling(src: str, dst: str) -> object:
            if src == str(source):
                source.write_text('{application,alpha,[{vsn,"2"}]}.')
            return shutil.copy2(src, dst)

        result = neovim_prepare.seed(self.workspace, recompiling)
        assert (result["seeded"], result["skipped"]) == (["beta"], {"alpha": "changed during copy"})
        assert self.published() == ["beta"]

    def test_build_copied_from_another_checkout_is_left_for_elixirls(self) -> None:
        # Navigation would return the other checkout's deps/. After a copied _build,
        # Mix rebuilds Elixir modules but can keep an Erlang one: one foreign BEAM counts.
        self.compiled("beta", Path("/elsewhere/deps/beta/src/beta_shims.erl"), "beta_shims")
        # Compressed BEAMs (Erlang's `compressed` option, used by idna) are read too.
        self.compiled("alpha", self.workspace / "deps/alpha/src/table.erl", "table", compress=True)
        # A `compile: false` dependency has only Mix's marker and nothing to name.
        (self.workspace / "deps/gamma").mkdir()
        (self.workspace / "_build/test/lib/gamma/.mix").mkdir(parents=True)
        result = neovim_prepare.seed(self.workspace)
        assert result["seeded"] == ["alpha", "gamma"]
        reason = "a BEAM does not name " + str(self.workspace / "deps/beta")
        assert result["skipped"] == {"beta": reason}
        assert self.published() == ["alpha", "gamma"]

    def test_unreadable_dependency_is_skipped_and_the_rest_seeded(self) -> None:
        ebin = self.workspace / "_build/test/lib/alpha/ebin"
        # copytree reports every failed file; a dependency Mix is rebuilding fails many.
        for name in ["alpha.app", *(f"extra{n}.txt" for n in range(5))]:
            (ebin / name).write_text("")
            (ebin / name).chmod(0)
            self.addCleanup((ebin / name).chmod, 0o644)
        result = neovim_prepare.seed(self.workspace)
        assert result["seeded"] == ["beta"]
        reason = result["skipped"]["alpha"]
        assert reason.startswith("copy failed:")
        assert str(ebin) in reason
        assert len(reason) <= 500
        assert self.published() == ["beta"]

    def test_interrupted_copy_publishes_nothing_and_the_next_run_recovers(self) -> None:
        def interrupted(_src: str, _dst: str) -> object:
            raise KeyboardInterrupt

        stopped = False
        try:
            neovim_prepare.seed(self.workspace, interrupted)
        except KeyboardInterrupt:
            stopped = True
        assert stopped
        assert self.published() == []
        # A killed run cannot clean up; staging is hidden from Mix and removed next time.
        killed = self.lib / ".seed-alpha-killed"
        killed.mkdir()
        (killed / "partial.beam").write_text("")
        assert neovim_prepare.seed(self.workspace)["seeded"] == ["alpha", "beta"]
        assert self.published() == ["alpha", "beta"]

    def test_prepare_runs_project_mix_in_the_test_environment_then_seeds(self) -> None:
        with mock.patch.dict(os.environ, {"MIX_ENV": "dev"}):
            result = self.prepare(tools(self.root))
        assert (result["status"], result["seeded"]) == ("seeded", ["alpha", "beta"])
        assert set(result["seconds"]) == {"deps_get", "deps_compile", "seed"}
        log = (self.root / "mix.log").read_text().splitlines()
        assert log == ["test deps.get --check-locked", "test deps.compile"]

    def test_prepared_build_runs_no_mix_and_drops_killed_staging(self) -> None:
        (self.lib / "beta").mkdir(parents=True)
        (self.lib / ".seed-alpha-killed").mkdir()
        result = self.prepare(tools(self.root))
        assert result["status"] == "ready"
        assert not (self.root / "mix.log").exists()
        # ElixirLS compiles alpha itself; nothing half-copied remains.
        assert self.published() == ["beta"]

    def test_failed_compile_or_unusable_toolchain_leaves_the_build_to_elixirls(self) -> None:
        for compile_exit, version, detail, runs in (
            (1, "1.20.4/29", "mix deps.compile exited 1", 2),
            # Checked first: no minute of Mix work when seeding cannot follow.
            (0, "1.19.5/28", "Project toolchain 1.19.5/28 differs from 1.20.4/29.1", 0),
        ):
            with self.subTest(detail=detail):
                shutil.rmtree(self.root / "bin", ignore_errors=True)
                (self.root / "mix.log").unlink(missing_ok=True)
                result = self.prepare(tools(self.root, compile_exit, version))
                assert (result["status"], result["detail"]) == ("not-seeded", detail)
                assert not (self.workspace / ".elixir_ls").exists()
                log = self.root / "mix.log"
                assert len(log.read_text().splitlines() if log.exists() else []) == runs
        # No project Mix: reported, never raised, so the caller still starts the client.
        result = self.prepare()
        detail = "Cannot use the project toolchain: Project Mix is not on PATH"
        assert (result["status"], result["detail"]) == ("not-seeded", detail)
        assert not (self.workspace / ".elixir_ls").exists()

    def test_mix_gets_no_input_and_leaves_the_callers_stdout_alone(self) -> None:
        # A caller may own stdin/stdout, as MCP's serve does; answer "y" if Mix reads it.
        code = (
            "import json, sys; from pathlib import Path; import neovim_prepare as p; "
            "print(json.dumps(p.prepare(Path(sys.argv[1]), Path(sys.argv[2]), '1.20.4/29.1')))"
        )
        # Current interpreter and a fixed script; paths are argv entries, no shell.
        run = subprocess.run(  # noqa: S603
            [sys.executable, "-c", code, str(self.workspace), str(self.root / "bundle")],
            cwd=Path(neovim_prepare.__file__).parent,
            env=os.environ | {"PATH": str(tools(self.root).parent)},
            input="y\ny\n",
            capture_output=True,
            text=True,
            check=True,
        )
        assert json.loads(run.stdout)["status"] == "seeded"
        assert "mix deps.get answer=none" in run.stderr
        assert "mix deps.compile answer=none" in run.stderr

    def test_project_mix_never_selects_the_bundle_compiler(self) -> None:
        bundle = self.root / "bundle"
        private = bundle / "toolchain/bin"
        private.mkdir(parents=True)
        shutil.copy2(tools(self.root), private / "mix")
        with mock.patch.dict(os.environ, {"PATH": f"{private}:{self.root / 'bin'}"}):
            refused = ""
            try:
                neovim_prepare.project_mix(bundle)
            except RuntimeError as error:
                refused = str(error)
            assert refused.startswith("PATH selects the bundle's private Mix")
        with mock.patch.dict(os.environ, {"PATH": str(self.root / "bin")}):
            assert neovim_prepare.project_mix(bundle) == self.root / "bin/mix"


if __name__ == "__main__":
    unittest.main()
