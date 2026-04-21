# VoxScribe accuracy harness

Phase 1 evaluation of the AAI streaming + Claude Haiku correction pipeline.

## What it measures

For every clip in `manifest.json`, across three modes:

| Mode        | `keyterms_prompt` | `/correct` pass |
|-------------|:-----------------:|:---------------:|
| `baseline`  |         ✗         |        ✗        |
| `keyterms`  |         ✓         |        ✗        |
| `corrected` |         ✓         |        ✓        |

Per clip:
- `partial_ms` — first non-empty partial after audio send begins
- `final_ms`   — final endOfTurn arrival relative to end of audio send
- `correction_ms` — Haiku `/correct` latency (corrected mode only)
- `accuracy`   — fraction of seeded terms present case-sensitively in the graded text (raw final for baseline/keyterms, corrected for corrected)

**Phase 1 gate:** ≥ 80% seeded-term accuracy in `corrected` mode, across all clips.

## Running

Install server dependencies (`pip install -r server/requirements.txt`), then from the repo root:

```bash
python -m server.eval.run_eval                     # all clips, all modes
python -m server.eval.run_eval --modes corrected   # one mode only
python -m server.eval.run_eval --only coffee_hinglish_01.wav
```

`ASSEMBLYAI_API_KEY` is read from `server/.env`. `ANTHROPIC_API_KEY` is required for the `corrected` mode.

## Recording fixtures

Audio lives under `server/eval/fixtures/` and is **git-ignored**. Collaborators re-record from the committed manifest.

Record each clip as **16 kHz mono 16-bit PCM WAV**. Simple options:

- macOS — QuickTime → File → New Audio Recording → export as `.m4a`, then convert:
  ```bash
  ffmpeg -i input.m4a -ac 1 -ar 16000 -sample_fmt s16 fixtures/tech_feature_01.wav
  ```
- Any tool that exports WAV — verify with `ffprobe fixtures/<clip>.wav` that it reports `16000 Hz, mono, s16`.

Speak the `expected_transcript` naturally. Pauses between sentences are fine (they help AAI commit turns). Try to keep recording length 5–15 s.

## Manifest schema

```jsonc
{
  "clip": "tech_feature_01.wav",          // filename under fixtures/
  "scenario_id": "tech_feature",          // matches demo-keyterms.json
  "expected_transcript": "…",             // reference text you'll speak
  "seeded_terms": ["VoxScribe", "…"]      // graded substring match, case-sensitive
}
```

`seeded_terms` must be a subset of that scenario's `terms` list in `ios/VoxScribe/VoxScribe/Resources/demo-keyterms.json` — otherwise you're grading for terms that were never seeded as biasing hints.
