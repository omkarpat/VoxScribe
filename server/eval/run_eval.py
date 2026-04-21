"""VoxScribe Phase 1 accuracy harness.

Runs each fixture clip through three modes:
    * baseline  – AAI streaming, no keyterms_prompt, no /correct
    * keyterms  – AAI streaming with keyterms_prompt, no /correct
    * corrected – AAI streaming with keyterms_prompt + Haiku /correct pass

Metrics per clip:
    * partial_ms  – first non-empty partial after streaming began
    * final_ms    – arrival of final endOfTurn relative to end of audio send
    * correction_ms – /correct latency (corrected mode only)
    * accuracy    – fraction of seeded terms appearing case-sensitively in the
      graded text (raw_final for baseline/keyterms, corrected for corrected)

Run from the project root:
    python -m server.eval.run_eval
    python -m server.eval.run_eval --modes keyterms corrected
    python -m server.eval.run_eval --only coffee_hinglish_01.wav
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
import wave
from dataclasses import dataclass, field
from pathlib import Path

import websockets
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent
SERVER_DIR = ROOT.parent
PROJECT_DIR = SERVER_DIR.parent

load_dotenv(dotenv_path=SERVER_DIR / ".env", override=True)
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from correction import correct_single_turn  # noqa: E402
from providers import AssemblyAIProvider  # noqa: E402
from schemas import VocabularyInput  # noqa: E402

MANIFEST_PATH = ROOT / "manifest.json"
FIXTURES_DIR = ROOT / "fixtures"
KEYTERMS_PATH = PROJECT_DIR / "ios/VoxScribe/VoxScribe/Resources/demo-keyterms.json"

CHUNK_MS = 100
REQUIRED_SAMPLE_RATE = 16000
REQUIRED_CHANNELS = 1
REQUIRED_SAMPLE_WIDTH = 2
PASS_THRESHOLD = 0.80
MODES = ("baseline", "keyterms", "corrected")


@dataclass
class ClipMetrics:
    mode: str
    clip: str
    scenario_id: str
    seeded_terms: list[str]
    partial_ms: float | None = None
    final_ms: float | None = None
    correction_ms: float | None = None
    raw_final_text: str = ""
    corrected_text: str = ""
    error: str | None = None

    @property
    def graded_text(self) -> str:
        return self.corrected_text if self.mode == "corrected" else self.raw_final_text

    @property
    def hits(self) -> int:
        return sum(1 for t in self.seeded_terms if t in self.graded_text)

    @property
    def accuracy(self) -> float:
        return (self.hits / len(self.seeded_terms)) if self.seeded_terms else 1.0


def _load_scenarios() -> dict[str, list[str]]:
    """Return {scenario_id: keyterms} from the iOS-bundled catalog so the
    harness shares one source of truth with the app."""
    with KEYTERMS_PATH.open() as f:
        catalog = json.load(f)
    return {s["id"]: s["terms"] for s in catalog["scenarios"]}


def _load_manifest(only: str | None) -> list[dict]:
    with MANIFEST_PATH.open() as f:
        manifest = json.load(f)
    clips = [c for c in manifest["clips"] if not c.get("clip", "").startswith("_")]
    if only:
        clips = [c for c in clips if c["clip"] == only]
        if not clips:
            sys.exit(f"No clip named {only!r} in manifest.")
    return clips


def _validate_wav(path: Path) -> None:
    with wave.open(str(path), "rb") as w:
        if w.getnchannels() != REQUIRED_CHANNELS:
            raise ValueError(f"{path.name}: must be mono, got {w.getnchannels()} channels")
        if w.getsampwidth() != REQUIRED_SAMPLE_WIDTH:
            raise ValueError(f"{path.name}: must be 16-bit PCM, got sampwidth={w.getsampwidth()}")
        if w.getframerate() != REQUIRED_SAMPLE_RATE:
            raise ValueError(f"{path.name}: must be 16 kHz, got {w.getframerate()} Hz")


async def _stream_clip(ws_url: str, wav_path: Path) -> list[tuple[float, dict]]:
    """Open the WS, send the wav in 100 ms chunks in real time, and collect
    every JSON message the server sends back. Returns (relative_ts, msg) pairs
    where ts is seconds since first audio chunk."""
    messages: list[tuple[float, dict]] = []
    send_start: float | None = None
    send_end_marker = {"_local": "send_end"}

    async with websockets.connect(ws_url, max_size=None) as ws:
        async def receiver() -> None:
            nonlocal send_start
            async for raw in ws:
                t = time.monotonic()
                msg = json.loads(raw)
                rel = (t - send_start) if send_start is not None else 0.0
                messages.append((rel, msg))
                if msg.get("type") == "Termination":
                    return

        async def sender() -> None:
            nonlocal send_start
            frames_per_chunk = int(REQUIRED_SAMPLE_RATE * CHUNK_MS / 1000)
            with wave.open(str(wav_path), "rb") as w:
                send_start = time.monotonic()
                while True:
                    frames = w.readframes(frames_per_chunk)
                    if not frames:
                        break
                    await ws.send(frames)
                    await asyncio.sleep(CHUNK_MS / 1000)
            # Local marker so we can measure latency relative to end of send.
            messages.append((time.monotonic() - send_start, send_end_marker))
            await ws.send(json.dumps({"type": "Terminate"}))

        await asyncio.gather(sender(), receiver())

    return messages


def _extract_metrics(messages: list[tuple[float, dict]]) -> tuple[float | None, float | None, str]:
    """Compute partial_ms, final_ms (seconds after end-of-send), and the
    concatenated final text from a clip's message stream."""
    partial_s: float | None = None
    send_end_s: float | None = None
    final_absolute_s: float | None = None
    finals: list[str] = []

    for rel, msg in messages:
        if msg.get("_local") == "send_end":
            send_end_s = rel
            continue
        if msg.get("type") != "Turn":
            continue
        text = (msg.get("transcript") or "").strip()
        eot = bool(msg.get("end_of_turn"))
        if partial_s is None and text:
            partial_s = rel
        if eot and text:
            finals.append(text)
            final_absolute_s = rel

    partial_ms = partial_s * 1000 if partial_s is not None else None
    final_ms: float | None = None
    if final_absolute_s is not None and send_end_s is not None:
        final_ms = max(0.0, final_absolute_s - send_end_s) * 1000
    return partial_ms, final_ms, " ".join(finals)


async def _run_mode(
    provider: AssemblyAIProvider,
    clip_meta: dict,
    scenarios: dict[str, list[str]],
    mode: str,
) -> ClipMetrics:
    seeded = list(clip_meta["seeded_terms"])
    metrics = ClipMetrics(
        mode=mode,
        clip=clip_meta["clip"],
        scenario_id=clip_meta["scenario_id"],
        seeded_terms=seeded,
    )

    wav_path = FIXTURES_DIR / clip_meta["clip"]
    if not wav_path.exists():
        metrics.error = f"missing fixture: {wav_path}"
        return metrics
    try:
        _validate_wav(wav_path)
    except ValueError as e:
        metrics.error = str(e)
        return metrics

    vocabulary = VocabularyInput(
        keyterms_prompt=scenarios[clip_meta["scenario_id"]] if mode != "baseline" else []
    )

    try:
        token = await provider.issue_token(vocabulary)
    except Exception as e:
        metrics.error = f"token error: {e}"
        return metrics

    try:
        messages = await _stream_clip(token.ws_url, wav_path)
    except Exception as e:
        metrics.error = f"ws error: {e}"
        return metrics

    partial_ms, final_ms, raw_final = _extract_metrics(messages)
    metrics.partial_ms = partial_ms
    metrics.final_ms = final_ms
    metrics.raw_final_text = raw_final

    if mode == "corrected":
        t0 = time.monotonic()
        try:
            metrics.corrected_text = await correct_single_turn(
                raw_final, scenarios[clip_meta["scenario_id"]]
            )
        except Exception as e:
            metrics.error = f"correct error: {e}"
            metrics.corrected_text = raw_final
        metrics.correction_ms = (time.monotonic() - t0) * 1000

    return metrics


def _format_ms(v: float | None) -> str:
    return f"{v:>7.0f}" if v is not None else "      —"


def _print_per_clip(results: list[ClipMetrics]) -> None:
    print()
    print("Per-clip results")
    print("-" * 110)
    header = f"{'mode':<10} {'clip':<28} {'partial_ms':>10} {'final_ms':>9} {'corr_ms':>8} {'hits':>8} {'acc':>6}"
    print(header)
    print("-" * 110)
    for r in results:
        hits = f"{r.hits}/{len(r.seeded_terms)}"
        acc = f"{r.accuracy * 100:5.1f}%"
        line = (
            f"{r.mode:<10} {r.clip:<28} "
            f"{_format_ms(r.partial_ms):>10} {_format_ms(r.final_ms):>9} {_format_ms(r.correction_ms):>8} "
            f"{hits:>8} {acc:>6}"
        )
        if r.error:
            line += f"   ! {r.error}"
        print(line)


def _print_summary(results: list[ClipMetrics]) -> None:
    print()
    print("Summary by mode")
    print("-" * 80)
    print(f"{'mode':<10} {'clips':>5} {'median_partial':>16} {'median_final':>14} {'term_acc':>10}")
    print("-" * 80)
    for mode in MODES:
        subset = [r for r in results if r.mode == mode and not r.error]
        if not subset:
            continue
        partials = [r.partial_ms for r in subset if r.partial_ms is not None]
        finals = [r.final_ms for r in subset if r.final_ms is not None]
        hits = sum(r.hits for r in subset)
        total = sum(len(r.seeded_terms) for r in subset)
        acc = hits / total if total else 0.0
        mp = f"{statistics.median(partials):6.0f} ms" if partials else "      —"
        mf = f"{statistics.median(finals):6.0f} ms" if finals else "      —"
        print(f"{mode:<10} {len(subset):>5} {mp:>16} {mf:>14} {acc * 100:>9.1f}%")

    corrected = [r for r in results if r.mode == "corrected" and not r.error]
    if corrected:
        hits = sum(r.hits for r in corrected)
        total = sum(len(r.seeded_terms) for r in corrected)
        acc = hits / total if total else 0.0
        verdict = "PASS" if acc >= PASS_THRESHOLD else "FAIL"
        print()
        print(
            f"Phase 1 gate (corrected mode, ≥{PASS_THRESHOLD * 100:.0f}% seeded-term accuracy): "
            f"{acc * 100:.1f}%  →  {verdict}"
        )


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="VoxScribe accuracy harness")
    p.add_argument(
        "--modes",
        nargs="+",
        choices=list(MODES),
        default=list(MODES),
        help="Which modes to run (default: all three).",
    )
    p.add_argument(
        "--only",
        type=str,
        default=None,
        help="Limit to a single clip by filename (e.g. tech_feature_01.wav).",
    )
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    if not os.getenv("ASSEMBLYAI_API_KEY"):
        sys.exit("ASSEMBLYAI_API_KEY not set; see server/.env.example.")
    if "corrected" in args.modes and not os.getenv("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY not set; required for 'corrected' mode.")

    scenarios = _load_scenarios()
    clips = _load_manifest(args.only)
    missing = [c["clip"] for c in clips if not (FIXTURES_DIR / c["clip"]).exists()]
    if missing:
        print("Missing fixtures — record them into server/eval/fixtures/ (16 kHz mono 16-bit WAV):")
        for m in missing:
            print(f"  - {m}")
        print("See server/eval/README.md for recording guidance. Running available clips only.")
        print()

    provider = AssemblyAIProvider(api_key=os.environ["ASSEMBLYAI_API_KEY"])
    results: list[ClipMetrics] = []
    for clip in clips:
        for mode in args.modes:
            print(f"[run] mode={mode:<10} clip={clip['clip']}")
            result = await _run_mode(provider, clip, scenarios, mode)
            results.append(result)
            if result.error:
                print(f"       error: {result.error}")
            else:
                print(f"       graded: {result.graded_text[:120]!r}")

    _print_per_clip(results)
    _print_summary(results)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main()))
