"""Adversarial eval runner for VoxScribe /correct.

Usage:
    python -m server.eval.adversarial [--url URL] [--n N] [--report PATH]

Exits non-zero if any gate fails.
"""

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import httpx

from .assertions import run_assertion

CASES_DIR = Path(__file__).parent / "cases"
DEFAULT_URL = "http://127.0.0.1:8000"
DEFAULT_N = 3

# Gates: category_slug → minimum pass rate (0.0–1.0). "protected_terms" is 0.95.
# "self_correction" is 1.0 (100%). Everything else: 0.85.
GATES: dict[str, float] = {
    "protected_terms": 0.95,
    "self_correction": 1.00,
}
DEFAULT_GATE = 0.85
FALLBACK_RATE_GATE = 0.05  # overall fallback rate on non-fallback_expected cases must be < 5%


def _load_cases() -> list[dict[str, Any]]:
    cases = []
    seen_ids: set[str] = set()
    for path in sorted(CASES_DIR.glob("*.json")):
        with path.open() as f:
            data = json.load(f)
        category = path.stem  # e.g. "01_protected_terms"
        for case in data:
            case_id = case["id"]
            if case_id in seen_ids:
                raise ValueError(f"duplicate adversarial case id: {case_id}")
            seen_ids.add(case_id)
            case["_category"] = category
            cases.append(case)
    return cases


def _post_correct(base_url: str, case: dict) -> str | None:
    """POST to /correct, return the corrected text or None on HTTP/network error."""
    payload = {
        "session_id": "eval",
        "vocabulary_revision": 1,
        "protected_terms": case.get("protected_terms", []),
        "profile": case.get("profile", "default"),
        "transcriber": case.get("transcriber", "standard"),
        "detected_language": case.get("detected_language"),
        "turns": [{"turn_order": 1, "transcript": case["input_transcript"]}],
    }
    try:
        resp = httpx.post(f"{base_url}/correct", json=payload, timeout=15.0)
        resp.raise_for_status()
        data = resp.json()
        return data["segments"][0]["text"]
    except Exception as exc:
        print(f"  [HTTP error] {exc}", file=sys.stderr)
        return None


def _run_case(base_url: str, case: dict, n: int) -> dict[str, Any]:
    """Run a single case N times, return aggregated results."""
    raw = case["input_transcript"]
    assertions = case.get("assertions", [])
    has_fallback_expected = any(a["type"] == "fallback_expected" for a in assertions)

    run_results = []
    for _ in range(n):
        output = _post_correct(base_url, case)
        if output is None:
            run_results.append({"output": None, "assertion_results": [], "passed": False, "is_fallback": False})
            continue

        is_fallback = output.strip() == raw.strip()
        assertion_results = [
            {"assertion": a, "result": run_assertion(a, raw, output)}
            for a in assertions
        ]
        all_passed = all(r["result"][0] for r in assertion_results)
        run_results.append({
            "output": output,
            "assertion_results": assertion_results,
            "passed": all_passed,
            "is_fallback": is_fallback,
        })

    majority_pass = sum(r["passed"] for r in run_results) > n / 2
    any_fallback = any(r["is_fallback"] for r in run_results if r["output"] is not None)

    return {
        "case_id": case["id"],
        "category": case["_category"],
        "raw": raw,
        "profile": case.get("profile", "default"),
        "transcriber": case.get("transcriber", "standard"),
        "detected_language": case.get("detected_language"),
        "has_fallback_expected": has_fallback_expected,
        "runs": run_results,
        "majority_pass": majority_pass,
        "any_fallback": any_fallback,
    }


def _category_slug(category_dir_name: str) -> str:
    """'01_protected_terms' → 'protected_terms'."""
    parts = category_dir_name.split("_", 1)
    return parts[1] if len(parts) == 2 else category_dir_name


def run_eval(base_url: str, n: int, report_path: Path) -> bool:
    """Run all cases. Returns True if all gates pass."""
    cases = _load_cases()
    if not cases:
        print("No cases found in", CASES_DIR, file=sys.stderr)
        return False

    print(f"Running {len(cases)} cases × N={n} against {base_url}/correct …\n")

    results = []
    for case in cases:
        print(f"  {case['id']} ({case['_category']}) … ", end="", flush=True)
        result = _run_case(base_url, case, n)
        results.append(result)
        status = "PASS" if result["majority_pass"] else "FAIL"
        fallback_note = " [fallback]" if result["any_fallback"] and not result["has_fallback_expected"] else ""
        print(f"{status}{fallback_note}")
        if not result["majority_pass"]:
            # Print first failing run's details
            for run in result["runs"]:
                for ar in run.get("assertion_results", []):
                    if not ar["result"][0]:
                        print(f"    ↳ {ar['result'][1]}")
                break

    # ---------------------------------------------------------------------------
    # Aggregate per-category
    # ---------------------------------------------------------------------------
    from collections import defaultdict
    cat_total: dict[str, int] = defaultdict(int)
    cat_pass: dict[str, int] = defaultdict(int)
    non_fallback_cases = 0
    fallback_count = 0

    for r in results:
        slug = _category_slug(r["category"])
        cat_total[slug] += 1
        if r["majority_pass"]:
            cat_pass[slug] += 1
        if not r["has_fallback_expected"]:
            non_fallback_cases += 1
            if r["any_fallback"]:
                fallback_count += 1

    overall_pass = sum(r["majority_pass"] for r in results)
    overall_total = len(results)
    fallback_rate = fallback_count / max(non_fallback_cases, 1)

    # ---------------------------------------------------------------------------
    # Gate evaluation
    # ---------------------------------------------------------------------------
    gate_failures: list[str] = []

    print("\n--- Category Results ---")
    for slug in sorted(cat_total):
        total = cat_total[slug]
        passed = cat_pass[slug]
        rate = passed / total
        gate = GATES.get(slug, DEFAULT_GATE)
        ok = rate >= gate
        mark = "✓" if ok else "✗"
        print(f"  {mark} {slug}: {passed}/{total} ({rate:.0%}) [gate ≥{gate:.0%}]")
        if not ok:
            gate_failures.append(f"{slug}: {rate:.0%} < gate {gate:.0%}")

    fallback_ok = fallback_rate < FALLBACK_RATE_GATE
    fallback_mark = "✓" if fallback_ok else "✗"
    print(f"\n  {fallback_mark} overall fallback rate: {fallback_rate:.1%} [gate <{FALLBACK_RATE_GATE:.0%}]")
    if not fallback_ok:
        gate_failures.append(f"fallback_rate: {fallback_rate:.1%} ≥ gate {FALLBACK_RATE_GATE:.0%}")

    print(f"\nTotal: {overall_pass}/{overall_total} cases passed")

    # ---------------------------------------------------------------------------
    # Write markdown report
    # ---------------------------------------------------------------------------
    _write_report(report_path, results, cat_total, cat_pass, fallback_rate, gate_failures)
    print(f"Report written to {report_path}")

    if gate_failures:
        print("\nGATE FAILURES:")
        for f in gate_failures:
            print(f"  ✗ {f}")
        return False

    print("\nAll gates passed.")
    return True


def _write_report(
    path: Path,
    results: list[dict],
    cat_total: dict,
    cat_pass: dict,
    fallback_rate: float,
    gate_failures: list[str],
) -> None:
    from collections import defaultdict
    lines = ["# Adversarial Eval Report\n"]

    lines.append("## Summary\n")
    lines.append(f"Total cases: {len(results)}  ")
    lines.append(f"Passed: {sum(r['majority_pass'] for r in results)}  ")
    lines.append(f"Fallback rate (positive cases): {fallback_rate:.1%}\n")

    if gate_failures:
        lines.append("### Gate Failures\n")
        for f in gate_failures:
            lines.append(f"- {f}")
        lines.append("")
    else:
        lines.append("**All gates passed.**\n")

    lines.append("## Per-Category\n")
    lines.append("| Category | Passed | Total | Rate | Gate |")
    lines.append("|----------|--------|-------|------|------|")
    for slug in sorted(cat_total):
        total = cat_total[slug]
        passed = cat_pass[slug]
        rate = passed / total
        gate = GATES.get(slug, DEFAULT_GATE)
        ok = "✓" if rate >= gate else "✗"
        lines.append(f"| {ok} {slug} | {passed} | {total} | {rate:.0%} | ≥{gate:.0%} |")

    lines.append("")
    lines.append("## Failed Cases\n")
    failed = [r for r in results if not r["majority_pass"]]
    if not failed:
        lines.append("None.\n")
    else:
        for r in failed:
            lines.append(f"### {r['case_id']} ({r['category']})\n")
            lines.append(f"**Profile**: `{r['profile']}`  ")
            lines.append(f"**Transcriber**: `{r['transcriber']}`  ")
            if r["detected_language"] is not None:
                lines.append(f"**Detected language**: `{r['detected_language']}`  ")
            lines.append(f"**Input**: `{r['raw']}`\n")
            for run in r["runs"]:
                if run["output"] and not run["passed"]:
                    lines.append(f"**Output**: `{run['output']}`\n")
                    for ar in run["assertion_results"]:
                        if not ar["result"][0]:
                            lines.append(f"- {ar['result'][1]}")
                    break
            lines.append("")

    path.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(description="VoxScribe adversarial eval runner")
    parser.add_argument("--url", default=DEFAULT_URL, help="FastAPI base URL")
    parser.add_argument("--n", type=int, default=DEFAULT_N, help="Runs per case (majority-pass)")
    parser.add_argument(
        "--report",
        default=str(Path(__file__).parent / "report.md"),
        help="Path for markdown report",
    )
    args = parser.parse_args()

    ok = run_eval(args.url, args.n, Path(args.report))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
