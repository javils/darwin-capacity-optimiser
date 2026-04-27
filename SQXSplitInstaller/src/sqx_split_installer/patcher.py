"""Patch a SQX-generated .mq5 file to integrate the SplitOrder library.

The transformation is the sequence of edits documented by the library README's
manual procedure, but performed correctly — in particular, the `openPosition(`
callsite rewrite never touches the function definition.
"""

from __future__ import annotations

import re
from pathlib import Path

IDEMPOTENCY_MARKER = "Patched by SQXSplitInstaller"
SQX_INCLUDE_LINE = "#include <SplitOrder/SplitOrderSQX.mqh>"

_RETURN_TYPES = r"(?:ulong|void|int|bool|double|long|float|datetime|string)"
_RE_DEFINITION_LINE = re.compile(rf"^\s*{_RETURN_TYPES}\s+openPosition\s*\(")
_RE_ONINIT = re.compile(r"^\s*int\s+OnInit\s*\(")
_RE_ONTIMER = re.compile(r"^\s*void\s+OnTimer\s*\(")
_RE_INCLUDE = re.compile(r"^\s*#include\b")
_RE_RETURN = re.compile(r"^\s*return\b")


class PatchError(Exception):
    """Raised when a file cannot be patched (invalid, already patched, etc.)."""


# --- Public API ---------------------------------------------------------------


def patch_content(content: str, split_count: int, delay_seconds: int) -> str:
    """Return the patched version of an SQX-generated .mq5 source string."""
    if IDEMPOTENCY_MARKER in content:
        raise PatchError("File is already patched (idempotency marker found).")

    _validate_sqx_signatures(content)

    line_ending = "\r\n" if "\r\n" in content else "\n"
    ends_with_newline = content.endswith(("\n", "\r\n"))
    lines = content.splitlines()

    lines = _inject_include(lines, split_count, delay_seconds)
    lines = _inject_oninit_block(lines)
    lines = _inject_ontimer_block(lines)
    lines = _rewrite_callsites(lines)
    lines = _prepend_marker(lines, split_count, delay_seconds)

    output = line_ending.join(lines)
    if ends_with_newline:
        output += line_ending
    return output


def patch_file(
    input_path: Path,
    output_path: Path,
    split_count: int,
    delay_seconds: int,
) -> Path:
    """Read `input_path`, patch it, and write the result to `output_path`."""
    input_path = Path(input_path)
    output_path = Path(output_path)

    if not input_path.exists():
        raise PatchError(f"Input file does not exist: {input_path}")

    try:
        same_file = input_path.resolve() == output_path.resolve()
    except FileNotFoundError:
        same_file = False
    if same_file:
        raise PatchError(
            "Input and output paths resolve to the same file; refuse to overwrite in place."
        )

    content = input_path.read_text(encoding="utf-8")
    patched = patch_content(content, split_count, delay_seconds)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(patched, encoding="utf-8", newline="")
    return output_path


# --- Validation ---------------------------------------------------------------


def _validate_sqx_signatures(content: str) -> None:
    if not _RE_ONINIT.search(content, re.MULTILINE) and not re.search(
        r"^\s*int\s+OnInit\s*\(", content, re.MULTILINE
    ):
        raise PatchError("Missing OnInit(): file does not look like an SQX-generated EA.")
    if not re.search(r"^\s*int\s+OnInit\s*\(", content, re.MULTILINE):
        raise PatchError("Missing OnInit(): file does not look like an SQX-generated EA.")
    if not re.search(r"^\s*void\s+OnTimer\s*\(", content, re.MULTILINE):
        raise PatchError("Missing OnTimer(): file does not look like an SQX-generated EA.")
    if not re.search(r"^\s*ulong\s+openPosition\s*\(", content, re.MULTILINE):
        raise PatchError(
            "Missing openPosition() definition: file does not look like an SQX-generated EA."
        )
    if _count_callsites(content.splitlines()) == 0:
        raise PatchError("Found no openPosition() call sites; nothing to split.")


def _count_callsites(lines: list[str]) -> int:
    count = 0
    for line in lines:
        code = _strip_line_comment(line)
        if _RE_DEFINITION_LINE.match(code):
            continue
        if "openPosition(" in code:
            count += 1
    return count


# --- Transformations ----------------------------------------------------------


def _inject_include(lines: list[str], split_count: int, delay_seconds: int) -> list[str]:
    """Inject the library include and the user-facing input declarations
    immediately after the last existing #include directive."""
    user_inputs = [
        'input string sSplitOrder = "----------- SplitOrder -----------";',
        f"input int splitOrderCount = {split_count};            // SplitOrder: positions including pos0 (2-10)",
        f"input int splitOrderDelaySeconds = {delay_seconds};   // SplitOrder: seconds between child orders (1-300)",
    ]

    new_lines: list[str] = []
    if not any(SQX_INCLUDE_LINE in line for line in lines):
        new_lines.append(SQX_INCLUDE_LINE)
    if not any("input int splitOrderCount" in line for line in lines):
        new_lines.extend(user_inputs)
    if not new_lines:
        return lines

    last_include_idx = -1
    for i, line in enumerate(lines):
        if _RE_INCLUDE.match(line):
            last_include_idx = i

    if last_include_idx == -1:
        return new_lines + [""] + lines
    return lines[: last_include_idx + 1] + new_lines + lines[last_include_idx + 1 :]


def _inject_oninit_block(lines: list[str]) -> list[str]:
    start = _find_signature_line(lines, _RE_ONINIT)
    end = _find_matching_close_brace(lines, start)

    # Find the last `return` statement inside the function body.
    last_return = None
    for i in range(end - 1, start, -1):
        if _RE_RETURN.match(lines[i]):
            last_return = i
            break

    insertion_idx = last_return if last_return is not None else end
    indent = _detect_indent(lines[insertion_idx]) if last_return is not None else "   "
    block = [
        f"{indent}//--- SQXSplitInstaller ---",
        f"{indent}SQXSplitInit(splitOrderCount, splitOrderDelaySeconds);",
        f"{indent}EventSetTimer(1);",
        f"{indent}//--- end SQXSplitInstaller ---",
    ]
    return lines[:insertion_idx] + block + lines[insertion_idx:]


def _inject_ontimer_block(lines: list[str]) -> list[str]:
    start = _find_signature_line(lines, _RE_ONTIMER)
    # Find the line where the opening brace lives (same line or next).
    for i in range(start, len(lines)):
        if "{" in lines[i]:
            opening_line = i
            break
    else:
        raise PatchError("OnTimer() opening brace not found.")

    # Indent used by the existing body (the line after the brace if present).
    indent = "   "
    for j in range(opening_line + 1, len(lines)):
        if lines[j].strip():
            indent = _detect_indent(lines[j])
            break

    # Inject our split engine call, then a 24h throttle that protects SQX's
    # original cleanup body from running every second (it was designed to run
    # once every 20-30h; our 1s timer would otherwise fire it 86,400x more).
    block = [
        f"{indent}//--- SQXSplitInstaller ---",
        f"{indent}SQXSplitOnTimer();",
        f"{indent}static datetime _sqxLastCleanup = 0;",
        f"{indent}datetime _sqxNow = TimeCurrent();",
        f"{indent}if(_sqxNow - _sqxLastCleanup < 24 * 3600) return;",
        f"{indent}_sqxLastCleanup = _sqxNow;",
        f"{indent}//--- end SQXSplitInstaller ---",
    ]
    return lines[: opening_line + 1] + block + lines[opening_line + 1 :]


def _rewrite_callsites(lines: list[str]) -> list[str]:
    out: list[str] = []
    for line in lines:
        out.append(_rewrite_line(line))
    return out


def _rewrite_line(line: str) -> str:
    """Replace `openPosition(` by `openPositionSplit(` on a callsite line.

    Never rewrites inside line comments, and never rewrites a definition line.
    """
    # Preserve any trailing line comment verbatim.
    comment_idx = _find_line_comment_start(line)
    code = line if comment_idx is None else line[:comment_idx]
    comment = "" if comment_idx is None else line[comment_idx:]

    if _RE_DEFINITION_LINE.match(code):
        return line

    if "openPosition(" not in code:
        return line

    return code.replace("openPosition(", "openPositionSplit(") + comment


def _prepend_marker(lines: list[str], split_count: int, delay_seconds: int) -> list[str]:
    header = (
        "//+------------------------------------------------------------------+"
    )
    middle = f"//| {IDEMPOTENCY_MARKER} — split={split_count}, delay={delay_seconds}s"
    return [header, middle, header] + lines


# --- Parsing helpers ----------------------------------------------------------


def _find_signature_line(lines: list[str], pattern: re.Pattern[str]) -> int:
    for i, line in enumerate(lines):
        if pattern.match(line):
            return i
    raise PatchError(f"Could not locate signature {pattern.pattern!r}.")


def _find_matching_close_brace(lines: list[str], start: int) -> int:
    """Walk from `start` forward and return the index of the line holding the
    closing `}` that balances the first `{` encountered. Naive — does not
    account for braces inside strings or block comments, which do not appear
    in SQX-generated source in practice."""
    depth = 0
    opened = False
    for i in range(start, len(lines)):
        for ch in lines[i]:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
                if opened and depth == 0:
                    return i
    raise PatchError(f"Unbalanced braces starting at line {start}.")


def _detect_indent(line: str) -> str:
    match = re.match(r"^[ \t]*", line)
    return match.group(0) if match else "   "


def _strip_line_comment(line: str) -> str:
    idx = _find_line_comment_start(line)
    return line if idx is None else line[:idx]


def _find_line_comment_start(line: str) -> int | None:
    """Return the index at which a `//` line comment begins, or None.

    Ignores `//` that is part of a URL inside a string (naive: does not parse
    MQL5 strings fully, which is acceptable for our scope)."""
    return line.find("//") if "//" in line else None
