"""Tests for the `patch` command and the `patch_content` core function.

Tests are written to be structural — they derive their expectations from
the baseline fixture at runtime, so they work against any SQX-generated file.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from sqx_split_installer.patcher import (
    IDEMPOTENCY_MARKER,
    SQX_INCLUDE_LINE,
    PatchError,
    patch_content,
    patch_file,
)


FIXTURES = Path(__file__).parent / "fixtures"
BASELINE = (FIXTURES / "baseline_sqx.mq5").read_text(encoding="utf-8")


# --- fixture-derived structural helpers --------------------------------------


_DEFINITION_RE = re.compile(
    r"^\s*(?:ulong|void|int|bool|double|long|float|datetime|string)"
    r"\s+openPosition\s*\("
)


def _count_callsites(source: str) -> int:
    """Count openPosition( occurrences that are NOT the function definition."""
    count = 0
    for line in source.splitlines():
        code = line.split("//", 1)[0]
        if _DEFINITION_RE.match(code):
            continue
        if "openPosition(" in code:
            count += 1
    return count


def _first_body_line(source: str, signature_pattern: str) -> str:
    """Return the first non-empty code line of the function body matching
    `signature_pattern` (a substring, e.g. 'void OnTimer')."""
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if signature_pattern in line)
    past_brace = False
    for line in lines[start:]:
        if not past_brace and "{" in line:
            past_brace = True
            # Content after the `{` on the same line?
            remainder = line.split("{", 1)[1].strip()
            if remainder:
                return remainder
            continue
        if past_brace and line.strip():
            return line.rstrip()
    raise AssertionError(f"No body line found for {signature_pattern!r}")


# --- header marker ------------------------------------------------------------


def test_patched_output_starts_with_idempotency_marker() -> None:
    output = patch_content(BASELINE, split_count=3, delay_seconds=10)
    assert output.startswith("//+"), "Output should start with the marker comment block"
    assert IDEMPOTENCY_MARKER in output.splitlines()[1]


def test_header_marker_includes_parameters() -> None:
    output = patch_content(BASELINE, split_count=5, delay_seconds=15)
    first_lines = "\n".join(output.splitlines()[:3])
    assert "split=5" in first_lines
    assert "delay=15" in first_lines


# --- include injection --------------------------------------------------------


def test_include_line_is_inserted() -> None:
    output = patch_content(BASELINE, 3, 10)
    assert SQX_INCLUDE_LINE in output


def test_include_inserted_after_last_existing_include() -> None:
    output_lines = patch_content(BASELINE, 3, 10).splitlines()
    our_include_idx = next(
        i for i, line in enumerate(output_lines) if line == SQX_INCLUDE_LINE
    )
    # The immediately preceding line must be another #include — i.e. we
    # inserted right after the last pre-existing include.
    assert output_lines[our_include_idx - 1].lstrip().startswith("#include")


def test_user_inputs_injected_with_default_values() -> None:
    output = patch_content(BASELINE, split_count=5, delay_seconds=15)
    assert 'input string sSplitOrder = "----------- SplitOrder -----------";' in output
    assert "input int splitOrderCount = 5" in output
    assert "input int splitOrderDelaySeconds = 15" in output


def test_user_inputs_not_duplicated_when_re_running_logic_idempotent() -> None:
    pre_added = BASELINE.replace(
        "#include <Expert/Expert.mqh>",
        "#include <Expert/Expert.mqh>\ninput int splitOrderCount = 7;\ninput int splitOrderDelaySeconds = 20;",
    )
    output = patch_content(pre_added, 3, 10)
    assert output.count("input int splitOrderCount") == 1


def test_include_not_duplicated_if_already_present() -> None:
    pre_included = BASELINE.replace(
        "#include <Trade/SymbolInfo.mqh>",
        f"#include <Trade/SymbolInfo.mqh>\n{SQX_INCLUDE_LINE}",
    )
    output = patch_content(pre_included, 3, 10)
    assert output.count(SQX_INCLUDE_LINE) == 1


# --- OnInit injection ---------------------------------------------------------


def test_oninit_block_inserted_before_final_return() -> None:
    output = patch_content(BASELINE, 3, 10)
    lines = output.splitlines()
    oninit_body = _slice_function(lines, "int OnInit()")
    return_index = next(
        i for i, line in enumerate(oninit_body) if "return(INIT_SUCCEEDED)" in line
    )
    # SQXSplitInit and EventSetTimer(1) must appear before the return.
    before = "\n".join(oninit_body[:return_index])
    assert "SQXSplitInit(splitOrderCount, splitOrderDelaySeconds)" in before
    assert "EventSetTimer(1)" in before


def test_oninit_block_positioned_after_initTimer() -> None:
    """Our EventSetTimer(1) must run AFTER SQX's initTimer() so ours wins."""
    output = patch_content(BASELINE, 3, 10)
    init_timer_pos = output.index("initTimer();")
    our_event_pos = output.index("EventSetTimer(1);")
    assert our_event_pos > init_timer_pos


# --- OnTimer injection --------------------------------------------------------


def test_ontimer_call_inserted_before_original_body() -> None:
    original_first_body = _first_body_line(BASELINE, "void OnTimer")

    output = patch_content(BASELINE, 3, 10)
    our_call_pos = output.index("SQXSplitOnTimer()")
    original_body_pos = output.index(original_first_body)
    assert our_call_pos < original_body_pos


def test_ontimer_throttle_inserted_before_original_body() -> None:
    """The 24h throttle must appear between our SQXSplitOnTimer call and the
    original SQX body, so the cleanup runs once a day instead of every second."""
    original_first_body = _first_body_line(BASELINE, "void OnTimer")
    output = patch_content(BASELINE, 3, 10)

    our_call_pos = output.index("SQXSplitOnTimer()")
    throttle_pos = output.index("_sqxLastCleanup")
    body_pos = output.index(original_first_body)

    assert our_call_pos < throttle_pos < body_pos


def test_ontimer_original_body_is_preserved() -> None:
    original_first_body = _first_body_line(BASELINE, "void OnTimer")
    output = patch_content(BASELINE, 3, 10)
    assert original_first_body in output


# --- Call-site rewrite --------------------------------------------------------


def test_callsites_rewritten_to_openPositionSplit() -> None:
    original_callsites = _count_callsites(BASELINE)
    assert original_callsites > 0, "Fixture must contain at least one callsite"

    output = patch_content(BASELINE, 3, 10)
    assert output.count("openPositionSplit(") == original_callsites


def test_function_definition_not_renamed() -> None:
    """THE critical test — the bug in the README is that find-and-replace
    would rename the definition line, breaking the EA."""
    output = patch_content(BASELINE, 3, 10)
    assert "ulong openPosition(" in output
    assert "ulong openPositionSplit(" not in output


def test_comment_mentioning_openPosition_is_untouched() -> None:
    sentinel = "// SENTINEL: openPosition( inside a comment must survive patching"
    # Inject the sentinel right before the first #include.
    injected = BASELINE.replace("#include", f"{sentinel}\n#include", 1)

    output = patch_content(injected, 3, 10)
    assert sentinel in output, "Comment mentioning openPosition( was rewritten"


# --- Idempotence + validation -------------------------------------------------


def test_patching_already_patched_file_raises() -> None:
    patched = patch_content(BASELINE, 3, 10)
    with pytest.raises(PatchError, match="already patched"):
        patch_content(patched, 3, 10)


def test_missing_OnInit_is_rejected() -> None:
    bad = BASELINE.replace("int OnInit()", "int NotOnInit()")
    with pytest.raises(PatchError, match="OnInit"):
        patch_content(bad, 3, 10)


def test_missing_OnTimer_is_rejected() -> None:
    bad = BASELINE.replace("void OnTimer()", "void NotOnTimer()")
    with pytest.raises(PatchError, match="OnTimer"):
        patch_content(bad, 3, 10)


def test_missing_openPosition_definition_is_rejected() -> None:
    bad = BASELINE.replace("ulong openPosition(ENUM_ORDER_TYPE", "ulong notOpenPosition(ENUM_ORDER_TYPE")
    with pytest.raises(PatchError, match="openPosition"):
        patch_content(bad, 3, 10)


def test_no_callsites_is_rejected() -> None:
    # Rename every callsite but keep the function definition intact.
    lines = BASELINE.splitlines()
    neutered: list[str] = []
    for line in lines:
        code = line.split("//", 1)[0]
        if _DEFINITION_RE.match(code):
            neutered.append(line)
        else:
            neutered.append(line.replace("openPosition(", "fooPosition("))
    bad = "\n".join(neutered)
    assert _count_callsites(bad) == 0  # sanity: we really removed them all

    with pytest.raises(PatchError, match="no.*call"):
        patch_content(bad, 3, 10)


# --- Line endings preservation ------------------------------------------------


def test_lf_line_endings_preserved() -> None:
    lf_content = BASELINE.replace("\r\n", "\n")
    output = patch_content(lf_content, 3, 10)
    assert "\r\n" not in output


def test_crlf_line_endings_preserved() -> None:
    crlf_content = BASELINE.replace("\r\n", "\n").replace("\n", "\r\n")
    output = patch_content(crlf_content, 3, 10)
    # Output should have CRLF on every line (we check non-final lines).
    lines = output.split("\r\n")
    assert len(lines) > 10  # Multiple lines split by CRLF


# --- File-level API -----------------------------------------------------------


def test_patch_file_writes_output(tmp_path: Path) -> None:
    input_file = tmp_path / "strategy.mq5"
    input_file.write_text(BASELINE, encoding="utf-8")
    output_file = tmp_path / "strategy_split.mq5"

    patch_file(input_file, output_file, split_count=3, delay_seconds=10)

    assert output_file.exists()
    assert IDEMPOTENCY_MARKER in output_file.read_text(encoding="utf-8")


def test_patch_file_rejects_same_input_and_output(tmp_path: Path) -> None:
    input_file = tmp_path / "strategy.mq5"
    input_file.write_text(BASELINE, encoding="utf-8")

    with pytest.raises(PatchError, match="same"):
        patch_file(input_file, input_file, 3, 10)


def test_patch_file_missing_input_raises(tmp_path: Path) -> None:
    missing = tmp_path / "nope.mq5"
    with pytest.raises(PatchError, match="does not exist"):
        patch_file(missing, tmp_path / "out.mq5", 3, 10)


# --- CLI integration ----------------------------------------------------------


def test_cli_patch_single_file_default_output(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    from sqx_split_installer.cli import main

    input_file = tmp_path / "strategy.mq5"
    input_file.write_text(BASELINE, encoding="utf-8")

    exit_code = main(["patch", str(input_file)])

    assert exit_code == 0
    expected_output = tmp_path / "strategy_split.mq5"
    assert expected_output.exists()


def test_cli_patch_with_output_dir_and_suffix(tmp_path: Path) -> None:
    from sqx_split_installer.cli import main

    input_file = tmp_path / "strategy.mq5"
    input_file.write_text(BASELINE, encoding="utf-8")
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    exit_code = main([
        "patch",
        "--split-count", "5",
        "--delay-seconds", "15",
        "--output-dir", str(out_dir),
        "--suffix", "_patched",
        str(input_file),
    ])

    assert exit_code == 0
    assert (out_dir / "strategy_patched.mq5").exists()


def test_cli_patch_multiple_files(tmp_path: Path) -> None:
    from sqx_split_installer.cli import main

    files = []
    for i in range(3):
        f = tmp_path / f"strategy{i}.mq5"
        f.write_text(BASELINE, encoding="utf-8")
        files.append(f)

    exit_code = main(["patch", *[str(f) for f in files]])

    assert exit_code == 0
    for i in range(3):
        assert (tmp_path / f"strategy{i}_split.mq5").exists()


def test_cli_patch_split_count_out_of_range(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    from sqx_split_installer.cli import main

    input_file = tmp_path / "strategy.mq5"
    input_file.write_text(BASELINE, encoding="utf-8")

    with pytest.raises(SystemExit):
        main(["patch", "--split-count", "1", str(input_file)])


def test_cli_patch_mixed_success_and_failure(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    from sqx_split_installer.cli import main

    good = tmp_path / "good.mq5"
    good.write_text(BASELINE, encoding="utf-8")
    bad = tmp_path / "bad.mq5"
    bad.write_text("not an SQX file", encoding="utf-8")

    exit_code = main(["patch", str(good), str(bad)])

    assert exit_code == 1  # At least one failed.
    assert (tmp_path / "good_split.mq5").exists()
    assert not (tmp_path / "bad_split.mq5").exists()


# --- helpers ------------------------------------------------------------------


def _slice_function(lines: list[str], signature: str) -> list[str]:
    """Return the lines of the function body that starts with `signature`.

    Walks balanced braces from the opening `{` to the matching `}`.
    """
    start = next(i for i, line in enumerate(lines) if signature in line)
    depth = 0
    body: list[str] = []
    started = False
    for line in lines[start:]:
        for ch in line:
            if ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
        if started:
            body.append(line)
        if started and depth == 0:
            return body
    return body
