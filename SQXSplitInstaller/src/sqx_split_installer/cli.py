"""Command-line interface for SQXSplitInstaller.

Two subcommands:
- install <terminal-folder>:   copy the SplitOrder library into MT5
- patch <input.mq5>...:        patch SQX-generated strategies (not yet implemented)
"""

from __future__ import annotations

import argparse
import sys
from importlib.metadata import version
from pathlib import Path
from typing import Sequence

from sqx_split_installer.install import InstallError, install_library

__version__ = version("sqx-split-installer")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sqx-split-installer",
        description="Install SplitOrder library into MetaTrader 5 and patch SQX-generated Expert Advisors to use it.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    install = subparsers.add_parser("install", help="Install the SplitOrder library into a MetaTrader 5 terminal.")
    install.add_argument("terminal_folder", type=Path, help="Path to the MT5 terminal root (the folder that contains MQL5/).")

    return parser


def _run_install(terminal_folder: Path) -> int:
    try:
        installed = install_library(terminal_folder)
    except InstallError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    dest = installed[0].parent
    print(f"Installed {len(installed)} files to {dest}:")
    for path in installed:
        print(f"  - {path.name}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "install":
        return _run_install(args.terminal_folder)

    parser.error(f"unknown command: {args.command}")
    return 2  # unreachable — parser.error raises SystemExit


if __name__ == "__main__":
    raise SystemExit(main())
