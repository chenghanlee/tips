"""Dispatcher launch tests using fake clients and Herdr; never create live panes."""

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from team import execute


class DispatchTest(unittest.TestCase):
    def test_launch_in_new_pane_preserves_caller_and_config(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dispatch test ") as directory:
            root = Path(directory)
            scripts = root / "agent/teams"
            scripts.mkdir(parents=True)
            shutil.copy2(Path(__file__).resolve().parents[1] / "dispatch", scripts / "dispatch")
            config = root / "custom config.toml"
            config.write_text(
                '[dispatcher]\nmodel="test-model"\neffort="high"\ncompact_percent=42\n'
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "calls"
            stub = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["DISPATCH_LOG"], "a") as output:
    output.write(json.dumps([Path(sys.argv[0]).name, args]) + "\\n")
if args[:2] == ["pane", "layout"]:
    print(json.dumps({"result": {"layout": {"panes": [
        {"pane_id": "caller", "rect": {"width": 140, "height": 40}}
    ]}}}))
elif args[:2] == ["pane", "split"]:
    print(json.dumps({"result": {"pane": {"pane_id": "new-pane"}}}))
"""
            for name in ("herdr", "claude"):
                program = bin_dir / name
                program.write_text(stub)
                program.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                HERDR_ENV="1",
                HERDR_PANE_ID="caller",
                TIPS_TEAM_CONFIG=str(config),
                DISPATCH_LOG=str(log),
            )
            result = execute([scripts / "dispatch", "--new-pane"], env=env, check=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            assert all(name == "herdr" for name, _ in calls), result.stdout
            split = next(args for _, args in calls if args[:2] == ["pane", "split"])
            assert "--current" in split
            assert "--no-focus" in split
            assert split[split.index("--cwd") + 1] == str(root)
            run = next(args for _, args in calls if args[:2] == ["pane", "run"])
            assert run[2] == "new-pane"
            execute(["bash", "-c", run[3]], env=env, check=True)
            launched = json.loads(log.read_text().splitlines()[-1])
            assert launched[0] == "claude"
            assert launched[1][:6] == [
                "--permission-mode",
                "auto",
                "--model",
                "test-model",
                "--effort",
                "high",
            ]
            assert "$HERDR_PANE_ID" in launched[1][-1]
