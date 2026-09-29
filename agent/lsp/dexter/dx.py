#!/usr/bin/env python3
"""Command-line entry point for the saved-file Dexter adapter."""

import sys

from dexter_client.cli import main

if __name__ == "__main__":
    sys.exit(main())
