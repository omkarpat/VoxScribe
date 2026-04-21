# VoxScribe

iOS streaming dictation demo. AssemblyAI Universal-3 for live ASR over WebSocket, Claude Haiku for per-turn cleanup, and a thin FastAPI server that mints tokens and runs the correction pass. Audio never transits our server — the iOS client streams straight to AAI.

See [`plan.md`](plan.md) for architecture and design principles, and [`phase2-plan.md`](phase2-plan.md) for the current milestone (Phase 1 is complete — see [`phase1-plan.md`](phase1-plan.md)).

## Repo layout

```
VoxScribe/
  plan.md, phase{1..5}-plan.md    # architecture + roadmap
  ios/VoxScribe/                  # Xcode project (SwiftUI, iOS 17+)
  server/
    main.py                       # FastAPI app
    providers/                    # StreamingProvider protocol + AAI impl
    correction.py                 # Haiku /correct implementation
    eval/                         # accuracy harness (run_eval.py + manifest)
    .env.example
```

## Quick start

Prereqs: Xcode 15+, Python 3.11+, an AssemblyAI key, an Anthropic key.

### Server

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # then fill in ASSEMBLYAI_API_KEY and ANTHROPIC_API_KEY
uvicorn main:app --host 127.0.0.1 --port 8000
```

Smoke checks:

```bash
curl http://127.0.0.1:8000/health
# → {"status":"ok","provider":"assemblyai"}

curl -X POST http://127.0.0.1:8000/token \
  -H 'content-type: application/json' -d '{"keyterms_prompt":[]}'
# → {"provider":"assemblyai","token":"…","ws_url":"wss://…","sample_rate":16000,"expires_in_seconds":600}
```

### iOS

1. Open `ios/VoxScribe/VoxScribe.xcodeproj` in Xcode.
2. `Config/AppConfig.swift` defaults to `http://127.0.0.1:8000` on the simulator. For a physical device, change the device branch to your machine's LAN IP.
3. Build and run on an iPhone simulator (iOS 17+). Tap the mic, speak, and watch partials/finals roll in.

Tap the gear icon in the top-left to open **Settings**, which holds:

- A segmented **mode** picker (Standard / Dictation / Structured) that selects the `/correct` profile — `default`, `dictation`, or `structured_entry` server-side. The mode can be changed anytime.
- An editable **keyterms** list: add, rename (tap a row), and swipe-to-delete. Terms bias the transcriber and are sent as `protected_terms` to `/correct`. Keyterm edits are disabled while recording — stop the session first; changes take effect on the next session. The list is persisted in `UserDefaults` and seeded with a default tech vocabulary on first launch.

## Provider abstraction

`StreamingProvider` (server, `server/providers/base.py`) + `StreamingTranscriberClient` (iOS, `Streaming/StreamingTranscriberClient.swift`) form the swap boundary. To add a new ASR provider:

1. Write `server/providers/foo.py` implementing `issue_token(vocabulary) -> TokenResponse`, returning a fully-formed `ws_url` for the new provider.
2. Write `ios/.../Streaming/FooStreamingClient.swift` implementing `StreamingTranscriberClient`, parsing the provider's message frames into the shared `ServerMessage` enum.
3. Point `main.py` at the new provider.

No other code should need to change.

## Accuracy harness

```bash
python -m server.eval.run_eval                    # all clips × all modes
python -m server.eval.run_eval --modes corrected  # single mode
```

Audio fixtures live under `server/eval/fixtures/` (gitignored); record them per the committed `server/eval/manifest.json`. See [`server/eval/README.md`](server/eval/README.md).

## Secrets

`ASSEMBLYAI_API_KEY` and `ANTHROPIC_API_KEY` live in `server/.env` only. The iOS binary never contains either key.
