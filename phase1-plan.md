# Phase 1 — Core streaming + seeded vocabulary + minimal cleanup

**Goal**: Tap Record, speak, see words appear live, and have finalized turns become more polished a beat later without sacrificing the hot path. Phase 1 is the demo path: fast live ASR, seeded domain vocabulary, and a minimal term-aware `/correct`.

**Architecture bias**
- One iOS app
- One FastAPI service
- No database
- No queue or background jobs
- No audio proxy
- No provider abstraction layer

**Success criteria**
- Partial-transcript latency (mic → on-screen) is perceptibly under 150 ms.
- Corrected-final latency is usually under 1 second after a raw final lands.
- Seeded proper nouns and demo terms are recognized correctly in the eval set often enough to feel trustworthy.
- No AssemblyAI API key or Anthropic API key is present anywhere in the iOS app or its binary.
- Every session ends with a `Terminate` message.
- Partial, raw-final, and corrected-final transcripts are visually distinguishable, with corrections replacing raw finals in the same row.
- Correction failure or timeout leaves the raw final in place. The row never reverts to empty.

## Task order

### 1. Repo scaffolding
- `ios/` Xcode project (SwiftUI app, iOS 17+, bundle id TBD). Use synchronized root groups.
- `server/` FastAPI skeleton: `main.py`, `requirements.txt` (`fastapi`, `uvicorn[standard]`, `httpx`, `python-dotenv`), `.env.example`.
- `.env.example` documents:
  - `ASSEMBLYAI_API_KEY=`
  - `ANTHROPIC_API_KEY=`
- Add `ios/VoxScribe/VoxScribe/Resources/demo-keyterms.json` (inside the target folder so Xcode synchronized root groups bundle it automatically) with **two demo scenarios**:
  - `tech_feature` — tech discussion about building an LLM-in-the-loop feature. Terms: Anthropic, Claude, Haiku, Sonnet, Opus, AssemblyAI, WebSocket, FastAPI, uvicorn, SwiftUI, Xcode, AVAudioEngine, PCM, ASR, VAD, LLM, prompt caching, VoxScribe.
  - `coffee_hinglish` — casual coffee-shop conversation with Hinglish code-switching. Terms: yaar, bhai, bhaiya, didi, accha, arre, matlab, bas, haan, na, kya, chalo, theek hai, chai, pani, masala, lassi, samosa, paratha, biryani, Mumbai, Delhi, Bengaluru, desi, jugaad, timepass. **Intentional stress test for `protected_terms`**: these words are phonetically close to English words ("yaar" ≈ "year", "bhai" ≈ "bye", "bas" ≈ "bus"), so Haiku will be tempted to "correct" them and `/correct` must not let it.
- Schema: `{default_scenario_id: string, scenarios: [{id, name, description, terms: string[]}]}`. A single `terms` array per scenario feeds both AssemblyAI's `keyterms_prompt` and `/correct`'s `protected_terms`.
- Root `.gitignore` additions: `server/.env`, Python `__pycache__`, macOS `.DS_Store`, Xcode user state, build artifacts.

### 2. FastAPI endpoints
- Load `ASSEMBLYAI_API_KEY` and `ANTHROPIC_API_KEY` from `.env` at startup; fail fast if missing.
- `GET /health` → `{status: "ok"}`.
- `GET /token` → calls `GET https://streaming.assemblyai.com/v3/token?expires_in_seconds=600` with the AssemblyAI key and forwards `{token, expires_in_seconds}` to the client.
- `POST /correct` → real Phase 1 cleanup using the forward-compatible request shape:
  - Request:
    - `session_id`
    - `vocabulary_revision` — accepted and logged, but the Phase 1 server does not branch on it. Reserved for Phase 2's dynamic vocabulary updates.
    - `protected_terms`
    - `turns`
  - Response:
    - `segments[{id, source_turn_orders, text, replaces_segment_ids?}]` — `replaces_segment_ids` is optional; omit or use `[]` for text-only edits. Phase 1 always omits.
    - Phase 1 id behavior: the server echoes the client's `turn-{turn_order}` id back as `segment.id` for every returned segment. Text-only edits reuse the incoming id; Phase 1 never mints new opaque ids.
- Haiku prompt layout (cache-friendly):
  - System prompt (prompt-cached): instructions + few-shot examples. Scenario-agnostic so the cache survives scenario switches.
  - User message (per-call): `protected_terms` block + the single `turns` entry. Small, variable, not cached.
- Phase 1 `/correct` scope:
  - single-turn only,
  - punctuation,
  - truecasing,
  - light filler removal,
  - preserve `protected_terms` exactly,
  - never add content,
  - preserve self-corrections verbatim — "two no actually three" stays as-is (with punctuation). Self-correction resolution is Phase 3's job and must not leak into Phase 1's Haiku prompt.
- Safety checks:
  - if the model drops a protected term that was present in the raw transcript, fall back to raw;
  - if corrected text length is wildly different from input, fall back to raw.
- The server remains stateless in Phase 1: no persistence layer, no job queue, no cache.
- Smoke tests:
  - `curl localhost:8000/token`
  - `curl -X POST localhost:8000/correct ...`

### 3. iOS — app config + server client
- `Config/AppConfig.swift`:
  - simulator default: `http://127.0.0.1:8000`
  - device override: LAN IP or tunnel URL
- `Networking/ServerClient.swift` wraps both server endpoints.
  - `func fetchToken() async throws -> String`
  - `func correct(sessionId: String, vocabulary: SessionVocabulary, turns: [TurnInput]) async throws -> [Segment]`
- Correction timeout: 3 seconds. On failure, caller keeps existing segments.
- Info.plist:
  - ATS exception for local dev hosts only (`NSAllowsLocalNetworking = YES` under `NSAppTransportSecurity`). Xcode can't express nested dicts as `INFOPLIST_KEY_*`, so this lives in a physical `Info.plist` file alongside the synthesized one.
  - `NSMicrophoneUsageDescription` — added via `INFOPLIST_KEY_NSMicrophoneUsageDescription` in the target build settings (synthesized into `Info.plist` at build time).

### 4. iOS — session vocabulary resolver
- `Vocabulary/SessionVocabulary.swift` loads `demo-keyterms.json` and selects the active scenario by id.
- Use the iOS 17+ `@Observable` macro (not `ObservableObject`) for the resolver — cleaner state observation, no Combine import.
- Active scenario selection: defaults to the JSON's `default_scenario_id`; overridable via a dev-mode scenario picker (see Task 8).
- Outputs for the selected scenario:
  - `keytermsPrompt: [String]` — fed into AssemblyAI WS `keyterms_prompt`.
  - `protectedTerms: [String]` — mirrored into every `/correct` request.
  - `revision: Int` — constant per session in Phase 1; bumps only if scenario changes (reserved for Phase 2 dynamic updates).
- Rules:
  - keep exact spelling and expected casing from the JSON;
  - cap at ~30–50 terms per scenario;
  - future user corrections can promote terms into `protectedTerms`, but that is additive and not required for the first demo.

### 5. iOS — audio capture
- `Audio/AudioCapture.swift`: wraps `AVAudioEngine`, installs a tap on the input node.
- Converts tap buffers to 16 kHz mono Int16 PCM via `AVAudioConverter`.
- Emits `Data` chunks of about 50 ms each via `AsyncStream<Data>`.
- Smoke: log chunk byte counts and cadence.

### 6. iOS — streaming client
- `Streaming/StreamingClient.swift`: wraps `URLSessionWebSocketTask`.
- Connects to AssemblyAI with:
  - required audio params,
  - `format_turns=true`,
  - `keyterms_prompt` from `SessionVocabulary`.
- The optional streaming `prompt=...` param is deliberately left **unwired** in Phase 1. We rely on `keyterms_prompt` alone for recognition biasing. Revisit in Phase 2 only if eval shows it's warranted.
- Sends audio as binary frames.
- Decodes inbound JSON into a typed `ServerMessage` enum: `.begin`, `.turn`, `.termination`.
- `close()` sends `{"type":"Terminate"}`, awaits `Termination`, then cancels the task.

### 7. iOS — session orchestrator
- `Session/TranscriptionSession.swift` composes `ServerClient`, `SessionVocabulary`, `AudioCapture`, and `StreamingClient`.
- `start()`:
  - resolve session vocabulary,
  - fetch token,
  - open WS,
  - capture `session_id` from `Begin`,
  - start pumping audio chunks into the WS.
- `stop()`:
  - stop mic,
  - send `Terminate`,
  - wait for `Termination`,
  - close.
- On `Turn` with `end_of_turn=false`: update the in-progress partial.
- On `Turn` with `end_of_turn=true`:
  1. Commit a raw-final segment with `id = "turn-{turn_order}"`.
  2. Fire a detached task: `ServerClient.correct(...)`.
  3. Apply the response transactionally using preserved ids and `replaces_segment_ids` (treat a missing `replaces_segment_ids` as `[]`).
- Phase 1 simplification:
  - the correction window is always just the one new turn;
  - no dynamic `UpdateConfiguration` yet;
  - no cross-turn rewrite yet.

### 8. iOS — UI
- `Views/TranscriptionView.swift`: big Record/Stop button, elapsed time, scrolling transcript.
- `ForEach` over segments keyed by `segment.id`.
- In-progress partial: lighter-weight draft style.
- Raw-final segments: slightly muted to signal "pending cleanup."
- Corrected segments: full-opacity normal state.
- Text swaps animate subtly.
- Error banner for:
  - mic permission denied,
  - token fetch failed,
  - WS connect failed,
  - WS dropped.
- Correction errors remain silent and preserve the raw text.
- Dev controls (hidden in release builds, e.g. behind `#if DEBUG`):
  - Scenario picker populated from `demo-keyterms.json`; defaults to `default_scenario_id`.
  - Small label above the transcript showing the active scenario name so the demo operator knows which biasing is in effect.

### 9. Accuracy harness
- Standalone script under `server/eval/` (e.g. `server/eval/run_eval.py`), runnable with `python -m server.eval.run_eval`. Not wired into the FastAPI app.
- Audio fixtures live under `server/eval/fixtures/` and are **gitignored** (add `server/eval/fixtures/` to `.gitignore`). A committed `server/eval/manifest.json` lists each clip's filename, scenario id, and expected transcript so collaborators can re-record locally from the same spec.
- Add a small real-voice eval set for the demo:
  - proper nouns,
  - product names,
  - acronyms,
  - a few natural filler-heavy phrases.
- Cover **both scenarios** (`tech_feature` and `coffee_hinglish`). The Hinglish set is the stronger test of `protected_terms` preservation.
- Record or script enough examples per scenario to compare:
  - baseline streaming,
  - streaming + `keyterms_prompt`,
  - streaming + `keyterms_prompt` + `/correct`.
- Track:
  - partial latency,
  - corrected-final latency,
  - seeded term accuracy,
  - manual post-edit count during dogfooding.
- Phase 1 pass threshold: **≥80% of seeded terms across the eval set appear exactly as specified (same spelling, same casing) in the corrected output.** Flat threshold across both scenarios — a single number keeps the harness honest and forces `coffee_hinglish` to actually work, not hide behind a lower bar.
- Keep the harness local and lightweight. Do not build a telemetry backend for Phase 1.

### 9b. Local partial streaming decision (physical device)
- Motivation: AAI Universal-Streaming emits immutable partials gated on pauses, leaving ~10-20 s gaps mid-utterance. To mask that, we wired an optional on-device `SFSpeechRecognizer` layer that paints the live partial text while AAI still owns the finalized turn. Confirmed broken on the iOS simulator (the Siri asset isn't installed); has to be judged on hardware.
- Gate: `AppConfig.localPartialStreamingEnabled` (currently `false`). Flip to `true` for the device evaluation.
- Files involved: `Speech/LocalSpeechRecognizer.swift`, the dual-stream (`AudioStreams.pcm` + `AudioStreams.buffers`) path in `AudioCapture`, the `localEnabled` branch in `TranscriptionSession`, `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` in the pbxproj.
- Pass criterion: partial text visibly refreshes ≥ every ~500 ms during continuous speech, with no regression in finalized turn accuracy.
- If it fails on device (erratic SFSR, worse UX, or no meaningful improvement in perceived latency): delete `Speech/`, revert `AudioStreams` back to a single `AsyncStream<Data>`, drop the `localRecognizer`/`localEnabled` wiring from `TranscriptionSession`, remove the flag from `AppConfig`, and remove the `NSSpeechRecognitionUsageDescription` key. AAI partials become the only partial source.
- If it passes: drop the flag and keep the path enabled by default.

### 10. End-to-end test
- `uvicorn` running locally.
- Build and run on simulator.
- Build and run on a physical device using a LAN IP or tunnel URL, not `localhost`.
- Record about 30 seconds of speech and verify:
  - partials appear under the latency target,
  - seeded terms survive the live path,
  - each finalized turn triggers `/correct`,
  - raw-final rows visibly swap to corrected rows,
  - `Terminate` is sent on Stop.

## Out of scope for Phase 1

- Self-correction resolution — within-turn or cross-turn. All of it is Phase 3.
- Cross-turn context or semantic rewrite
- Dynamic mid-stream vocabulary updates
- Dictation commands such as "period" or "new paragraph"
- Copy/export of transcript
- Reconnection logic if the WS drops
- Audio session interruption handling
- Background audio
- User-editable vocabulary settings UI
- Profile-derived vocabulary such as profession or specialty
- Database-backed persistence
- Background workers or queue-based correction
- Multi-provider routing or failover logic
- Server-side audio proxying
- Server deployment
