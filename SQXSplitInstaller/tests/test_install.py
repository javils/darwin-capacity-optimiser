"""Tests for the `install` command.

Covers copying the three .mqh library files into
<terminal>/MQL5/Include/SplitOrder/.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from sqx_split_installer.install import (
    LIBRARY_FILES,
    InstallError,
    install_library,
)


# --- helpers ------------------------------------------------------------------


def make_terminal(root: Path) -> Path:
    """Create a minimal MT5 terminal folder layout at `root` and return it."""
    (root / "MQL5" / "Include").mkdir(parents=True)
    (root / "MQL5" / "Experts").mkdir()
    return root


# --- success paths ------------------------------------------------------------


def test_install_creates_SplitOrder_subfolder(tmp_path: Path) -> None:
    terminal = make_terminal(tmp_path / "terminal")

    install_library(terminal)

    assert (terminal / "MQL5" / "Include" / "SplitOrder").is_dir()


def test_install_copies_all_three_mqh_files(tmp_path: Path) -> None:
    terminal = make_terminal(tmp_path / "terminal")

    install_library(terminal)

    dest = terminal / "MQL5" / "Include" / "SplitOrder"
    for filename in LIBRARY_FILES:
        assert (dest / filename).is_file(), f"Missing {filename}"


def test_install_file_contents_match_bundled_source(tmp_path: Path) -> None:
    terminal = make_terminal(tmp_path / "terminal")

    install_library(terminal)

    dest = terminal / "MQL5" / "Include" / "SplitOrder"
    for filename in LIBRARY_FILES:
        installed = (dest / filename).read_bytes()
        assert b"SplitOrder" in installed
        assert len(installed) > 100  # Not an empty or stub file


def test_install_overwrites_existing_files(tmp_path: Path) -> None:
    terminal = make_terminal(tmp_path / "terminal")
    dest = terminal / "MQL5" / "Include" / "SplitOrder"
    dest.mkdir()
    stale = dest / "SplitOrder.mqh"
    stale.write_text("// stale content")

    install_library(terminal)

    assert stale.read_text(encoding="utf-8") != "// stale content"


def test_install_returns_list_of_installed_files(tmp_path: Path) -> None:
    terminal = make_terminal(tmp_path / "terminal")

    result = install_library(terminal)

    assert isinstance(result, list)
    assert len(result) == len(LIBRARY_FILES)
    assert all(p.is_file() for p in result)


# --- failure paths ------------------------------------------------------------


def test_install_rejects_nonexistent_terminal_folder(tmp_path: Path) -> None:
    bogus = tmp_path / "nope"

    with pytest.raises(InstallError, match="does not exist"):
        install_library(bogus)


def test_install_rejects_path_that_is_not_a_directory(tmp_path: Path) -> None:
    file_path = tmp_path / "afile.txt"
    file_path.write_text("hi")

    with pytest.raises(InstallError, match="not a directory"):
        install_library(file_path)


def test_install_rejects_folder_without_MQL5(tmp_path: Path) -> None:
    terminal = tmp_path / "terminal"
    terminal.mkdir()
    (terminal / "config").mkdir()  # has something, but not MQL5

    with pytest.raises(InstallError, match="MQL5"):
        install_library(terminal)


# --- CLI integration ---------------------------------------------------------


def test_cli_install_success(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    from sqx_split_installer.cli import main

    terminal = make_terminal(tmp_path / "terminal")

    exit_code = main(["install", str(terminal)])

    assert exit_code == 0
    captured = capsys.readouterr()
    assert "SplitOrder" in captured.out


def test_cli_install_bad_path_exits_1(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    from sqx_split_installer.cli import main

    exit_code = main(["install", str(tmp_path / "missing")])

    assert exit_code == 1
    captured = capsys.readouterr()
    assert "does not exist" in captured.err
