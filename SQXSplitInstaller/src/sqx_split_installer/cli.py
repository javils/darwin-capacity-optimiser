"""Command-line interface for SQXSplitInstaller.

Two subcommands:
- install <terminal-folder>:   copy the SplitOrder library into MT5
- patch <input.mq5>...:        patch SQX-generated strategies with split integration
"""

from __future__ import annotations

import argparse
import sys
from importlib.metadata import version
from pathlib import Path
from typing import Sequence

from sqx_split_installer.install import InstallError, install_library
from sqx_split_installer.patcher import PatchError, patch_file

__version__ = version("sqx-split-installer")

SPLIT_COUNT_MIN, SPLIT_COUNT_MAX = 2, 100
DELAY_SECONDS_MIN, DELAY_SECONDS_MAX = 1, 300


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sqx-split-installer",
        description="Install SplitOrder library into MetaTrader 5 and patch SQX-generated Expert Advisors to use it.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    install = subparsers.add_parser("install", help="Install the SplitOrder library into a MetaTrader 5 terminal.")
    install.add_argument("terminal_folder", type=Path, help="Path to the MT5 terminal root (the folder that contains MQL5/).")

    patch = subparsers.add_parser("patch", help="Patch SQX-generated .mq5 files with SplitOrder integration.")
    patch.add_argument("inputs", nargs="+", type=Path, help="One or more SQX-generated .mq5 files.")
    patch.add_argument("--split-count", type=int, default=3, help=f"Total positions including pos0 ({SPLIT_COUNT_MIN}-{SPLIT_COUNT_MAX}). Default: 3.")
    patch.add_argument("--delay-seconds", type=int, default=10, help=f"Seconds between child orders ({DELAY_SECONDS_MIN}-{DELAY_SECONDS_MAX}). Default: 10.")
    patch.add_argument("--output-dir", type=Path, default=None, help="Destination directory for patched files. Default: alongside each input.")
    patch.add_argument("--suffix", default="_split", help="Suffix appended to the stem of the patched file. Default: _split.")

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


def _run_patch(
    inputs: list[Path],
    split_count: int,
    delay_seconds: int,
    output_dir: Path | None,
    suffix: str,
) -> int:
    successes: list[Path] = []
    failures: list[tuple[Path, str]] = []

    for input_path in inputs:
        out_dir = output_dir if output_dir is not None else input_path.parent
        output_path = out_dir / f"{input_path.stem}{suffix}.mq5"
        try:
            patch_file(input_path, output_path, split_count, delay_seconds)
            successes.append(output_path)
        except PatchError as exc:
            failures.append((input_path, str(exc)))
        except OSError as exc:
            failures.append((input_path, str(exc)))

    if successes:
        print(f"Patched {len(successes)} file(s):")
        for path in successes:
            print(f"  - {path}")
    if failures:
        print(f"\nFailed {len(failures)} file(s):", file=sys.stderr)
        for path, reason in failures:
            print(f"  - {path}: {reason}", file=sys.stderr)

    return 1 if failures else 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "install":
        return _run_install(args.terminal_folder)
    if args.command == "patch":
        if not SPLIT_COUNT_MIN <= args.split_count <= SPLIT_COUNT_MAX:
            parser.error(f"--split-count must be between {SPLIT_COUNT_MIN} and {SPLIT_COUNT_MAX}")
        if not DELAY_SECONDS_MIN <= args.delay_seconds <= DELAY_SECONDS_MAX:
            parser.error(f"--delay-seconds must be between {DELAY_SECONDS_MIN} and {DELAY_SECONDS_MAX}")
        return _run_patch(
            inputs=args.inputs,
            split_count=args.split_count,
            delay_seconds=args.delay_seconds,
            output_dir=args.output_dir,
            suffix=args.suffix,
        )

    parser.error(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
