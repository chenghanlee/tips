"""Run argv[2:] with the file argv[1] as stdin; stdout, stderr and exit status pass through."""

import subprocess
import sys

with open(sys.argv[1], "rb") as stdin:
    sys.exit(subprocess.run(sys.argv[2:], stdin=stdin, check=False).returncode)  # noqa: S603
