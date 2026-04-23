"""Deterministic validation for /correct_code Python output.

The validator is a safety filter, not a proof of correctness. It catches obvious
formatting and structural mistakes cheaply so the endpoint can fall back to raw
on model misfires.
"""

from __future__ import annotations

import ast
import re
from dataclasses import dataclass
from typing import Literal

SnippetKind = Literal["code", "code_header", "comment", "docstring", "mixed"]

HEADER_KEYWORDS = ("def", "class", "if", "elif", "else", "for", "while", "with", "try", "except", "finally")

_HEADER_PATTERN = re.compile(
    r"^\s*(?:async\s+)?(?:" + "|".join(HEADER_KEYWORDS) + r")\b"
)
_COMMENT_LINE = re.compile(r"^\s*#")
_TRIPLE_QUOTE = re.compile(r'("""|\'\'\')')


@dataclass
class ValidationResult:
    status: Literal["passed", "failed"]
    kind: SnippetKind
    checks: list[str]
    reason: str = ""


# ---------------------------------------------------------------------------
# Snippet-kind classifier
# ---------------------------------------------------------------------------

def classify(text: str) -> SnippetKind:
    stripped = text.strip()
    if not stripped:
        return "code"

    lines = [ln for ln in stripped.splitlines() if ln.strip()]

    # Docstring: starts AND ends with triple quotes and nothing else meaningful.
    if _TRIPLE_QUOTE.match(stripped) and _TRIPLE_QUOTE.search(stripped[3:]):
        return "docstring"

    # Pure comment(s).
    if lines and all(_COMMENT_LINE.match(ln) for ln in lines):
        return "comment"

    # Mixed: at least one comment line AND at least one non-comment code line.
    has_comment = any(_COMMENT_LINE.match(ln) for ln in lines)
    has_code = any(not _COMMENT_LINE.match(ln) for ln in lines)
    if has_comment and has_code:
        return "mixed"

    # Header: single-line or last-line ends with `:` under a header keyword, or
    # single-line header fragment without body.
    if len(lines) == 1 and _HEADER_PATTERN.match(lines[0]) and lines[0].rstrip().endswith(":"):
        return "code_header"

    return "code"


# ---------------------------------------------------------------------------
# Check helpers
# ---------------------------------------------------------------------------

def _delimiters_balanced(text: str) -> tuple[bool, str]:
    """Return (ok, reason). Skip content inside string literals."""
    pairs = {")": "(", "]": "[", "}": "{"}
    opens = set("([{")
    stack: list[str] = []

    i = 0
    n = len(text)
    in_string: str | None = None
    while i < n:
        ch = text[i]

        if in_string is not None:
            # Triple-quoted string?
            if text.startswith(in_string * 3, i):
                i += 3
                in_string = None
                continue
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == in_string:
                in_string = None
                i += 1
                continue
            i += 1
            continue

        if ch in ("'", '"'):
            if text.startswith(ch * 3, i):
                in_string = ch
                i += 3
                continue
            in_string = ch
            i += 1
            continue

        if ch == "#":
            # skip to end of line
            nl = text.find("\n", i)
            if nl == -1:
                break
            i = nl + 1
            continue

        if ch in opens:
            stack.append(ch)
        elif ch in pairs:
            if not stack or stack[-1] != pairs[ch]:
                return False, f"unbalanced delimiter at index {i}: {ch!r}"
            stack.pop()
        i += 1

    if stack:
        return False, f"unclosed delimiter(s): {''.join(stack)}"
    if in_string is not None:
        return False, f"unterminated string literal: {in_string!r}"
    return True, ""


def _newlines_normalized(text: str) -> tuple[bool, str]:
    if "\r" in text:
        return False, "carriage returns present"
    return True, ""


def _indentation_consistent(text: str) -> tuple[bool, str]:
    """Reject mixed tabs and spaces in the SAME leading-indent run.

    Single-line fragments and uniformly-indented snippets pass. Intentionally
    permissive: tabs or spaces alone are both fine.
    """
    for ln in text.splitlines():
        if not ln.strip():
            continue
        m = re.match(r"[ \t]*", ln)
        if not m:
            continue
        indent = m.group(0)
        if "\t" in indent and " " in indent:
            return False, f"mixed tab/space indentation: {ln!r}"
    return True, ""


def _validate_code(text: str) -> tuple[bool, str]:
    """Try parsing a complete snippet. If it fails as a module, try as an expression."""
    try:
        ast.parse(text)
        return True, ""
    except SyntaxError:
        pass
    try:
        ast.parse(text, mode="eval")
        return True, ""
    except SyntaxError as exc:
        return False, f"python parse failed: {exc.msg}"


def _validate_code_header(text: str) -> tuple[bool, str]:
    """Header fragments such as `def foo(self, x):`.

    Wrap with a pass body so ast can parse. This catches missing commas,
    unbalanced parens, and most punctuation slips without demanding a full
    function body that the dictation never produced.
    """
    stripped = text.rstrip()
    if not stripped.endswith(":"):
        return False, "code_header missing trailing ':'"
    # single-line header: wrap with pass body.
    wrapped = stripped + "\n    pass\n"
    try:
        ast.parse(wrapped)
        return True, ""
    except SyntaxError as exc:
        return False, f"python header parse failed: {exc.msg}"


def _validate_comment(text: str) -> tuple[bool, str]:
    # Already classified as all-comment lines; nothing further to check.
    return True, ""


def _validate_docstring(text: str) -> tuple[bool, str]:
    stripped = text.strip()
    quote = stripped[:3]
    if quote not in ('"""', "'''"):
        return False, "docstring does not start with triple quotes"
    if not stripped.endswith(quote):
        return False, "docstring not closed with matching triple quotes"
    return True, ""


def _validate_mixed(text: str) -> tuple[bool, str]:
    # Conservative: just confirm delimiters are balanced (already checked upstream)
    # and no stray triple-quote that isn't closed.
    triple_count = len(_TRIPLE_QUOTE.findall(text))
    if triple_count % 2 != 0:
        return False, "unbalanced triple-quote in mixed snippet"
    return True, ""


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

_VALIDATORS = {
    "code": _validate_code,
    "code_header": _validate_code_header,
    "comment": _validate_comment,
    "docstring": _validate_docstring,
    "mixed": _validate_mixed,
}


def validate(text: str) -> ValidationResult:
    kind = classify(text)
    checks = ["delimiter_balance", "newline_normalization", "indentation_consistency", "python_snippet_policy"]

    for check_name, runner in (
        ("delimiter_balance", _delimiters_balanced),
        ("newline_normalization", _newlines_normalized),
        ("indentation_consistency", _indentation_consistent),
    ):
        ok, reason = runner(text)
        if not ok:
            return ValidationResult(status="failed", kind=kind, checks=checks, reason=f"{check_name}: {reason}")

    ok, reason = _VALIDATORS[kind](text)
    if not ok:
        return ValidationResult(status="failed", kind=kind, checks=checks, reason=f"python_snippet_policy: {reason}")

    return ValidationResult(status="passed", kind=kind, checks=checks)
