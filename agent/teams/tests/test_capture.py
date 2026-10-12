"""The check-capture wrapper keeps full output and exit status in a fresh log every run."""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from team import execute

TEAMS = Path(__file__).resolve().parents[1]
PROGRAM = "import sys; print('line 1'); print('oops', file=sys.stderr); sys.exit(3)"


class CaptureTest(unittest.TestCase):
    def test_log_holds_output_and_exit_status_and_is_never_reused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            command = [sys.executable, str(TEAMS / "capture.py"), "suite/1", "--", sys.executable]
            first = execute([*command, "-c", PROGRAM], cwd=tmp, env=dict(os.environ))
            second = execute([*command, "-c", PROGRAM], cwd=tmp, env=dict(os.environ))
            logs = sorted(Path(tmp, "tmp/checks").iterdir())
            texts = [log.read_text() for log in logs]
        assert first.returncode == 3
        assert second.returncode == 3
        assert "line 1" in first.stdout
        assert "oops" in first.stdout
        named = [log for log in logs if f"capture: tmp/checks/{log.name} exit 3" in first.stderr]
        assert len(named) == 1, first.stderr
        assert len(logs) == 2, logs
        assert all("-suite-1" in log.name for log in logs)
        assert "# command: " in texts[0]
        assert "line 1\n" in texts[0]
        assert "oops\n" in texts[0]
        assert texts[0].rstrip().endswith("# exit 3 after 0s")

    def test_overlapping_runs_keep_both_logs(self) -> None:
        slow = "import sys, time; print('slow'); time.sleep(1.5); sys.exit(1)"
        fast = "import sys; print('fast'); sys.exit(0)"
        with tempfile.TemporaryDirectory() as tmp:
            command = [sys.executable, str(TEAMS / "capture.py"), "same", "--", sys.executable]
            env = dict(os.environ)
            with subprocess.Popen(  # noqa: S603 - test-owned interpreter and arguments
                [*command, "-c", slow], cwd=tmp, env=env, stdout=subprocess.PIPE, text=True
            ) as first:
                second = execute([*command, "-c", fast], cwd=tmp, env=env)
                first.wait(timeout=30)
            texts = sorted(log.read_text() for log in Path(tmp, "tmp/checks").iterdir())
        assert second.returncode == 0
        assert first.returncode == 1
        assert len(texts) == 2
        assert any("slow\n" in text and "# exit 1" in text for text in texts), texts
        assert any("fast\n" in text and "# exit 0" in text for text in texts), texts

    def test_interrupted_run_keeps_the_output_so_far(self) -> None:
        program = "import sys, time; print('partial', flush=True); time.sleep(30)"
        with tempfile.TemporaryDirectory() as tmp:
            command = [sys.executable, str(TEAMS / "capture.py"), "cut", "--", sys.executable]
            with subprocess.Popen(  # noqa: S603 - test-owned interpreter and arguments
                [*command, "-c", program], cwd=tmp, env=dict(os.environ)
            ) as process:
                deadline = time.monotonic() + 10
                logs: list[Path] = []
                while time.monotonic() < deadline:
                    logs = list(Path(tmp, "tmp/checks").glob("*.log"))
                    # The header echoes the command, so wait for the child's own line.
                    if logs and "partial" in logs[0].read_text().splitlines():
                        break
                    time.sleep(0.1)
                else:
                    self.fail("child output never reached the log")
                process.kill()
            assert "partial" in logs[0].read_text().splitlines()

    def test_usage_error_without_separator(self) -> None:
        result = execute([sys.executable, str(TEAMS / "capture.py"), "label", "echo"])
        assert result.returncode == 2
        assert "Usage" in result.stderr
