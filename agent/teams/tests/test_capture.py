"""The check-capture wrapper keeps full output and exit status in a fresh log every run."""

import os
import sys
import tempfile
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
        assert "oops" in first.stderr
        named = [log for log in logs if f"capture: tmp/checks/{log.name} exit 3" in first.stderr]
        assert len(named) == 1, first.stderr
        assert len(logs) == 2, logs
        assert all("-suite-1" in log.name for log in logs)
        assert "# command: " in texts[0]
        assert "line 1\n" in texts[0]
        assert "oops\n" in texts[0]
        assert texts[0].rstrip().endswith("# exit 3 after 0s")

    def test_usage_error_without_separator(self) -> None:
        result = execute([sys.executable, str(TEAMS / "capture.py"), "label", "echo"])
        assert result.returncode == 2
        assert "Usage" in result.stderr
