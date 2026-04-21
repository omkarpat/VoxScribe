"""Deterministic assertion helpers for the adversarial eval suite.

Every assertion is a pure function: (case_dict, output_text) → (passed: bool, detail: str).
No LLM-as-judge; all checks are substring / regex / set-membership / numeric.
"""

import re


def run_assertion(assertion: dict, raw_input: str, output: str) -> tuple[bool, str]:
    """Dispatch a single assertion. Returns (passed, detail_message)."""
    kind = assertion["type"]
    if kind == "contains_exact":
        return _contains_exact(assertion, output)
    if kind == "not_contains":
        return _not_contains(assertion, output)
    if kind == "protected_terms_preserved":
        return _protected_terms_preserved(assertion, raw_input, output)
    if kind == "length_ratio_between":
        return _length_ratio_between(assertion, raw_input, output)
    if kind == "does_not_resolve_self_correction":
        return _does_not_resolve_self_correction(assertion, output)
    if kind == "no_added_content":
        return _no_added_content(assertion, output)
    if kind == "fallback_expected":
        return _fallback_expected(raw_input, output)
    return False, f"unknown assertion type: {kind!r}"


# ---------------------------------------------------------------------------
# Assertion implementations
# ---------------------------------------------------------------------------

def _contains_exact(a: dict, output: str) -> tuple[bool, str]:
    """Output must contain the given substring (case-sensitive unless `ignore_case`)."""
    pattern = a["pattern"]
    flags = re.IGNORECASE if a.get("ignore_case") else 0
    if re.search(re.escape(pattern), output, flags):
        return True, f"contains_exact OK: {pattern!r}"
    return False, f"contains_exact FAIL: {pattern!r} not found in output"


def _not_contains(a: dict, output: str) -> tuple[bool, str]:
    """Output must NOT contain the given substring or regex pattern."""
    pattern = a["pattern"]
    use_regex = a.get("regex", False)
    flags = re.IGNORECASE if a.get("ignore_case") else 0
    search_pattern = pattern if use_regex else re.escape(pattern)
    if re.search(search_pattern, output, flags):
        return False, f"not_contains FAIL: {pattern!r} found in output"
    return True, f"not_contains OK: {pattern!r} absent"


def _protected_terms_preserved(a: dict, raw_input: str, output: str) -> tuple[bool, str]:
    """Every protected term that appears (case-insensitive) in the raw input
    must appear verbatim (case-sensitive) in the output."""
    terms: list[str] = a.get("terms", [])
    raw_lower = raw_input.lower()
    missing = [t for t in terms if t.lower() in raw_lower and t not in output]
    if missing:
        return False, f"protected_terms_preserved FAIL: dropped {missing}"
    return True, "protected_terms_preserved OK"


def _length_ratio_between(a: dict, raw_input: str, output: str) -> tuple[bool, str]:
    """len(output) / len(raw_input) must be in [min, max]."""
    raw_len = len(raw_input)
    if raw_len == 0:
        return True, "length_ratio_between OK (empty input)"
    ratio = len(output) / raw_len
    lo, hi = a["min"], a["max"]
    if lo <= ratio <= hi:
        return True, f"length_ratio_between OK: ratio={ratio:.2f} in [{lo}, {hi}]"
    return False, f"length_ratio_between FAIL: ratio={ratio:.2f} not in [{lo}, {hi}]"


def _does_not_resolve_self_correction(a: dict, output: str) -> tuple[bool, str]:
    """All marker tokens must still be present in the output.

    A self-correction like "two no actually three" should preserve both
    "two" and "three" in the output; resolving it to just "three" is a
    Phase 2 regression.
    """
    markers: list[str] = a["markers"]
    output_lower = output.lower()
    missing = [m for m in markers if m.lower() not in output_lower]
    if missing:
        return False, f"does_not_resolve_self_correction FAIL: markers {missing} missing from output"
    return True, "does_not_resolve_self_correction OK"


def _no_added_content(a: dict, output: str) -> tuple[bool, str]:
    """None of the forbidden_additions tokens should appear in the output."""
    forbidden: list[str] = a.get("forbidden_additions", [])
    output_lower = output.lower()
    found = [f for f in forbidden if f.lower() in output_lower]
    if found:
        return False, f"no_added_content FAIL: hallucinated tokens {found}"
    return True, "no_added_content OK"


def _fallback_expected(raw_input: str, output: str) -> tuple[bool, str]:
    """The output should equal the raw input (safety guard fired, raw preserved)."""
    # Strip trailing whitespace for comparison robustness.
    if output.strip() == raw_input.strip():
        return True, "fallback_expected OK: output == raw input"
    return False, f"fallback_expected FAIL: output differs from raw input\n  raw={raw_input!r}\n  out={output!r}"
