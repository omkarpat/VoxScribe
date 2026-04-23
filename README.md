# VoxScribe

iOS streaming dictation demo. AssemblyAI Universal-3 for live ASR over WebSocket, Claude Haiku for per-turn cleanup, and a thin FastAPI server that mints tokens and runs the correction pass. Audio never transits our server — the iOS client streams straight to AAI.

See [`plan.md`](plan.md) for architecture and design principles, and [`phase2-plan.md`](phase2-plan.md) for the current milestone (Phase 1 is complete — see [`phase1-plan.md`](phase1-plan.md)).

## Repo layout

```
VoxScribe/
  plan.md, phase{1..5}-plan.md    # architecture + roadmap
  correction-spec.md              # /correct (prose) behavioral contract
  code-mode-spec.md               # /correct_code (Python) behavioral contract
  ios/VoxScribe/                  # Xcode project (SwiftUI, iOS 17+)
  server/
    main.py                       # FastAPI app
    providers/                    # StreamingProvider protocol + AAI impl
    correction.py                 # Haiku /correct (prose) implementation
    code_correction.py            # Sonnet /correct_code (Python) generator
    code_validation.py            # deterministic Python validators
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

## Deploy to Railway

This repo is an isolated monorepo from Railway's point of view: the deployable backend lives in [`server/`](server), while the iOS app stays local. The committed [`server/Dockerfile`](server/Dockerfile) gives Railway a deterministic way to build and run the API.

1. Push your latest code to GitHub.
2. In Railway, create a new project and choose **Deploy from GitHub repo**.
3. After Railway creates the service, open **Settings** and set:
   - **Root Directory**: `/server`
   - **Healthcheck Path**: `/health`
4. Open the service's **Variables** tab and add the server secrets there. Do not commit a real `.env` file to git.

You can paste them into the Raw Editor like this:

```dotenv
ASSEMBLYAI_API_KEY=your_assemblyai_key
ANTHROPIC_API_KEY=your_anthropic_key
```

Railway injects those values as environment variables at runtime, which matches how `server/main.py` reads them. For local development, keep using `server/.env`.

5. Open **Settings > Networking** and click **Generate Domain** to get a public `https://...railway.app` URL.
6. Once the deploy is live, verify the server with:

```bash
curl https://your-service.up.railway.app/health
```

7. Update [`ios/VoxScribe/VoxScribe/Config/AppConfig.swift`](ios/VoxScribe/VoxScribe/Config/AppConfig.swift) so `serverBaseURL` points at your Railway URL instead of the local LAN address.

Notes:

- You do not need to define `PORT` yourself. Railway provides it automatically, and the Dockerfile starts Uvicorn on `0.0.0.0:$PORT`.
- Railway suggests variables from repository-root `.env` files. The root-level `.env.example` exists for that reason; the backend still uses `server/.env` locally.

Correction endpoints:

- `POST /correct` — prose cleanup. Profiles: `default`, `dictation`. Backed by
  Claude Haiku.
- `POST /correct_code` — Python code cleanup. English Standard transcriber
  only, `code_language: "python"` only. Backed by Claude Sonnet plus a
  deterministic validator; falls back to raw on API error, malformed output,
  or validation failure.

Smoke checks:

```bash
curl http://127.0.0.1:8000/health
# → {"status":"ok","provider":"assemblyai"}

curl -X POST http://127.0.0.1:8000/token \
  -H 'content-type: application/json' -d '{"keyterms_prompt":[],"transcriber":"standard"}'
# → {"provider":"assemblyai","token":"…","ws_url":"wss://…?speech_model=u3-rt-pro&…","sample_rate":16000,"expires_in_seconds":600}

curl -X POST http://127.0.0.1:8000/token \
  -H 'content-type: application/json' -d '{"keyterms_prompt":[],"transcriber":"multilingual"}'
# → {"provider":"assemblyai","token":"…","ws_url":"wss://…?speech_model=whisper-rt&language_detection=true&…", …}
```

### iOS

1. Open `ios/VoxScribe/VoxScribe.xcodeproj` in Xcode.
2. `Config/AppConfig.swift` defaults to `http://127.0.0.1:8000` on the simulator. For a physical device, change the device branch to your machine's LAN IP.
3. Build and run on an iPhone simulator (iOS 17+). Tap the mic, speak, and watch partials/finals roll in.

Tap the gear icon in the top-left to open **Settings**, which holds:

- A segmented **transcriber** picker (Standard / Multilingual). Standard runs AssemblyAI `u3-rt-pro` (English only) with a custom keyterms dictionary. Multilingual runs AssemblyAI `whisper-rt` across 99 languages with automatic language detection — the detected `language_code` is forwarded to `/correct` so the correction prompt can adapt. Keyterms aren't supported in Multilingual mode and the Keyterms section hides accordingly. The transcriber must be chosen before recording (it's baked into the streaming token).
- A segmented **mode** picker (Standard / Dictation) that selects the `/correct` profile — `default` or `dictation` server-side. Standard handles punctuation, casing, light cleanup, and common structured text such as emails, phone numbers, URLs, and IDs without inventing missing pieces; version/env-var/code shorthand is reserved for future Code mode. Dictation layers in spoken punctuation and line/paragraph commands. The mode can be changed anytime.
- An editable **keyterms** list (Standard transcriber only): add, rename (tap a row), and swipe-to-delete. Terms bias the transcriber and are sent as `protected_terms` to `/correct`. Keyterm edits are disabled while recording — stop the session first; changes take effect on the next session. The list is persisted in `UserDefaults` and seeded with a Hinglish vocabulary (yaar, chai, Mumbai, …) on first launch.

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

For local development, `ASSEMBLYAI_API_KEY` and `ANTHROPIC_API_KEY` live in `server/.env`.
For Railway, add the same keys in the service's Variables tab or Raw Editor instead of committing them.
The iOS binary never contains either key.
