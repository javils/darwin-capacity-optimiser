"""Install the SplitOrder library into a MetaTrader 5 terminal.

Copies the three `.mqh` files into `<terminal>/MQL5/Include/SplitOrder/`,
creating the destination subfolder if needed and overwriting existing files.

The library source files live at the repository root under `Include/SplitOrder/`.
When packaged as a PyInstaller executable, the files are embedded via
`--add-data` and extracted to `sys._MEIPASS/SplitOrder/` at runtime.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

LIBRARY_FILES = (
    "SplitOrder.mqh",
    "SplitOrderConfig.mqh",
    "SplitOrderSQX.mqh",
)


class InstallError(Exception):
    """Raised when the install operation cannot proceed due to a user-facing issue."""


def _source_library_dir() -> Path:
    """Return the directory that holds the library source files."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "SplitOrder"  # type: ignore[attr-defined]
    # From src/sqx_split_installer/install.py go up to the repo root.
    return Path(__file__).resolve().parents[3] / "Include" / "SplitOrder"


def install_library(terminal_folder: Path) -> list[Path]:
    """Copy the SplitOrder library into the terminal's `MQL5/Include/` directory.

    Returns the list of installed file paths.
    """
    terminal_folder = Path(terminal_folder)

    if not terminal_folder.exists():
        raise InstallError(f"Terminal folder does not exist: {terminal_folder}")

    if not terminal_folder.is_dir():
        raise InstallError(f"Terminal path is not a directory: {terminal_folder}")

    mql5_dir = terminal_folder / "MQL5"
    if not mql5_dir.is_dir():
        raise InstallError(f"No MQL5 folder found under {terminal_folder}. Point to the terminal root that contains MQL5/.")

    source_dir = _source_library_dir()
    include_dir = mql5_dir / "Include"
    include_dir.mkdir(exist_ok=True)
    dest = include_dir / "SplitOrder"
    dest.mkdir(exist_ok=True)

    installed: list[Path] = []
    for filename in LIBRARY_FILES:
        shutil.copyfile(source_dir / filename, dest / filename)
        installed.append(dest / filename)

    return installed
