"""The shared command helpers in this process."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from commands import write_file


class WriteFileTest(unittest.TestCase):
    def test_a_failed_write_keeps_the_old_text_and_a_later_one_replaces_it(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "1.json"
        path.write_text("old")
        # The disk refuses to make the staged text durable: the record is not touched.
        with (
            mock.patch.object(os, "fsync", side_effect=OSError("disk failed")),
            self.assertRaises(OSError),
        ):
            write_file(path, "new")
        assert path.read_text() == "old", "a failed write must leave the previous text"
        write_file(path, "new")
        assert path.read_text() == "new", "a completed write replaces the text"
        assert os.listdir(directory.name) == ["1.json"], "no staged file is left behind"


if __name__ == "__main__":
    unittest.main()
