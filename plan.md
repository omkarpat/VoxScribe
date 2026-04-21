# VoxScribe

iOS voice dictation demo app optimized for the thing users notice first: perceived accuracy at live speed. VoxLocal (fully on-device ASR) was shelved in favor of a cloud-first architecture that keeps the hot path fast while still allowing higher-quality cleanup after each finalized turn.

## Architecture

```
┌─────────────┐                                   ┌──────────────────┐
│  iOS client │◀──────── WebSocket ─────────────▶│  AssemblyAI      │
│  (SwiftUI)  │   binary PCM16 → AssemblyAI      │  /v3/ws          │
│             │   Turn events → client           │                  │
│             │   (hot path — <150ms partials)   │                  │
│             │                                   └──────────────────┘
│             │                                            ▲
│             │                                            │ HTTPS
│             │                                            │
│             │         ┌───────────────┐                  │
│             │◀─HTTPS─▶│  FastAPI      │──────────────────┘
│             │  /token │  server       │  /v3/token (key in .env)
│             │         │               │
│             │  /correct (async, per   │
│             │   finalized turn)       │
│             │◀────────│               │
└─────────────┘         └───────────────┘
```

- **Hot path (audio + partials):** iOS fetches a short-lived token from our server, then opens a WebSocket directly to AssemblyAI. Audio and partial transcript events never transit our server.
- **Accuracy path (live ASR):** each session starts with a session-scoped `keyterms_prompt` built from high-value terms for the demo. The streaming prompt stays conservative and close to AssemblyAI's default behavior so we do not trade away turn detection for cleverness.
- **Correction path (async):** on each `end_of_turn=true`, iOS renders the raw final immediately and POSTs the finalized turn to `/correct` together with protected spellings for the session. The corrected text patches the already-visible row in place. If `/correct` fails or times out, the raw text stays.
- **Server responsibilities:**
  - `POST /token` accepts `{keyterms_prompt}`, mints an AssemblyAI temp token via `/v3/token`, and returns a fully-formed WebSocket URL with all provider query params baked in. The iOS client just opens the URL — it doesn't know about provider-specific knobs like `speech_model`, `format_turns`, or `keyterms_prompt`.
  - `POST /correct` performs term-aware cleanup and later semantic rewrite.
- **Provider boundary:** a thin `StreamingProvider` interface sits in front of the AssemblyAI-specific token + URL logic. Swapping ASR providers means adding one concrete implementation of the interface plus a matching `StreamingTranscriberClient` on iOS that parses the new provider's message frames into the shared `ServerMessage` enum.
- **Why split the server from the audio stream:** routing audio through our server would add a full RTT to every partial and blow the latency budget. Audio goes direct; only the async correction layer touches our server.

## Simplicity strategy

We want the smallest architecture that can still produce a convincing demo.

- **One client, one thin server.** The iOS app captures audio and renders UI. The FastAPI server only mints tokens and runs `/correct`.
- **No audio proxy.** Audio never goes through our server.
- **No database for the demo.** Vocabulary seeds, eval fixtures, and local settings stay on device or in the repo. The server remains stateless.
- **No queue, cache tier, or background workers.** Correction happens inline inside the `/correct` request.
- **No multi-provider routing.** AssemblyAI owns live ASR. Anthropic owns cleanup and later rewrite. We do not build fallback orchestration for the demo.
- **No server-side transcript persistence.** If we need transcripts in the UI, they live on device.
- **No auth system yet.** Production safety rails come later; the demo path stays operationally simple.
- **Only add moving parts when the eval harness proves they buy visible quality.** If a feature does not materially improve the perceived speed/accuracy trade-off, it stays out.

## Repo layout

Monorepo:

```
VoxScribe/
  plan.md
  phase1-plan.md
  phase2-plan.md
  phase3-plan.md
  phase4-plan.md
  phase5-plan.md
  ios/          # Xcode project (SwiftUI, iOS 17+)
  server/       # FastAPI app
    main.py
    requirements.txt
    .env.example
```

## Tech stack

**iOS (`ios/`)**
- Swift 6, SwiftUI, iOS 17+
- `AVAudioEngine` + `AVAudioConverter` for 16 kHz mono Int16 PCM capture
- `URLSessionWebSocketTask` for streaming
- `@Observable` for state

**Server (`server/`)**
- Python 3.11+
- FastAPI + uvicorn
- `httpx` for outbound calls to AssemblyAI and Anthropic
- `python-dotenv` for config

## Audio pipeline

- Sample rate: **16000 Hz**
- Encoding: **`pcm_s16le`**
- Channels: mono
- Chunk cadence: ~50 ms → 800 samples → 1600 bytes per frame
- Input tap → `AVAudioConverter` → binary WebSocket frame

## AssemblyAI integration

**Model**: `u3-rt-pro` (Universal-3 Pro streaming).

**Token mint (server → AssemblyAI)**:
```
GET https://streaming.assemblyai.com/v3/token?expires_in_seconds=600
Authorization: <ASSEMBLYAI_API_KEY>
→ { "token": "...", "expires_in_seconds": 600 }
```

**WebSocket (iOS → AssemblyAI)**:
```
wss://streaming.assemblyai.com/v3/ws
  ?speech_model=u3-rt-pro
  &token=<temp_token>
  &sample_rate=16000
  &encoding=pcm_s16le
  &format_turns=true
  [&keyterms_prompt=<term> ...]
  [&prompt=<light instructional prompt>]
```

**Inbound messages**
- `Begin` — `{type, id, expires_at}` session confirmed
- `Turn` — `{type, transcript, end_of_turn, turn_is_formatted, words, ...}`
- `Termination` — `{type, audio_duration_seconds, session_duration_seconds}`

**Outbound messages**
- Binary frames — raw PCM16 audio chunks (50–1000 ms each)
- `{"type": "Terminate"}` — clean session close
- `{"type": "KeepAlive"}` — if needed during long silence
- `{"type": "ForceEndpoint"}` — force end-of-turn
- `{"type": "UpdateConfiguration", ...}` — future dynamic keyterm and prompt updates

**Partial vs final rendering**
- `Turn` with `end_of_turn: false` updates the in-progress partial.
- `Turn` with `end_of_turn: true` finalizes the row immediately.

**End-of-turn detection**
- AssemblyAI handles endpointing server-side. No local VAD is required.
- Tunable via query params:
  - `vad_threshold`
  - `min_turn_silence`
  - `max_turn_silence`
- Each `Turn` carries `end_of_turn_confidence` for optional client-side heuristics.

## Session vocabulary biasing

Goal: increase perceived accuracy where users notice mistakes most quickly, especially names, products, brands, acronyms, and domain terms.

**Current inputs**
- Demo seed terms checked into the repo or bundled with the app
- High-priority terms learned from recent user corrections during the same session
- Session-specific overrides for the current demo context

**Future inputs**
- Profile-derived packs such as profession or specialty

**Rules**
- Prefer exact spellings and expected casing.
- Avoid stuffing common words into `keyterms_prompt`.
- Cap the live session vocabulary to a practical shortlist (roughly 30-50 terms for the demo).
- Mirror the same shortlist into `/correct` as `protected_terms` so the cleanup model cannot "fix" the ASR back into the wrong spelling.

## Correction layer

Goal: partials render in under 150 ms from AssemblyAI, raw finals appear immediately, and finalized text is cleaned up asynchronously without blocking the UI.

### Capability ladder

| Phase | `/correct` does | Examples |
|---|---|---|
| 1 | Minimal single-turn cleanup via Claude Haiku | punctuation, truecasing, preserve protected terms, light filler removal |
| 2 | Stronger single-turn cleanup gated by an adversarial eval suite | tighter punctuation / truecase / filler handling, within-turn false-start cleanup, deterministic safety guards (length, protected-term mutation, schema) with raw fallback |
| 3 | **Windowed semantic rewrite** via Claude Haiku + rolling session memory | cross-turn self-correction ("let's meet at 2 no actually 3" → "Let's meet at 3.") with older frozen context compressed into a compact memory object |

**Self-correction is exclusively a Phase 3 capability.** Phases 1 and 2 do not resolve self-corrections, whether within a single turn ("two no actually three" spoken without pause) or across turns. Earlier phases will punctuate such utterances but leave the meaning verbatim.

The Phase 3 capability remains the hard requirement for project completion. It is the feature that turns "good live ASR" into "best-in-class scribe."

### Forward-compatible API shape

```
POST /correct
{
  "session_id": "uuid-from-Begin",
  "vocabulary_revision": 4,
  "protected_terms": ["AssemblyAI", "VoxScribe", "Haiku"],
  "turns": [
    {"turn_order": 5, "transcript": "lets meet at 2"},
    {"turn_order": 6, "transcript": "no actually 3"}
  ]
}
→
{
  "segments": [
    {
      "id": "seg-0007",
      "source_turn_orders": [5, 6],
      "text": "Let's meet at 3.",
      "replaces_segment_ids": ["turn-5", "turn-6"]
    }
  ]
}
```

Why this shape from day one:
- **Phase 1** sends one finalized turn plus `protected_terms`, receives one cleaned segment, and usually keeps the same row identity.
- **Phase 3** sends a multi-turn window and may merge, split, or delete earlier rows.
- The contract explicitly carries replacement semantics so structural rewrites are implementable without fragile ID guessing on the client.

### Segment identity and replacement semantics

- Raw finalized rows start life on the client with deterministic provisional ids: `turn-{turn_order}`.
- Text-only cleanup should preserve the existing segment id whenever possible.
- Structural rewrites create new opaque ids and must declare `replaces_segment_ids`.
- `replaces_segment_ids` may be omitted from a response; a missing value is equivalent to `[]`. Phase 1 responses typically omit it since Phase 1 is always one-turn-in, one-segment-out.
- The client applies a correction response transactionally:
  1. Update existing segments whose ids are preserved.
  2. Remove every id listed in `replaces_segment_ids`.
  3. Insert the new segments at the earliest replaced position.
- This gives us stable diffing for simple edits and an explicit, non-ambiguous path for merges and splits later.

### Flow per finalized turn (`end_of_turn=true`)

1. iOS commits `Turn.transcript` immediately as a raw-final row.
2. iOS POSTs the current correction window together with the session's `protected_terms`.
3. Server returns one or more corrected segments.
4. iOS reconciles the response in a single animation pass using preserved ids plus `replaces_segment_ids`.
5. If `/correct` fails or times out, the raw rows stay visible. No revert.

### Window definition

The correction window is "all finalized turns since the last commit point."

A commit point is:
- a long silence with high confidence,
- a manual paragraph break,
- or a sliding cap where the window never exceeds `N` turns (default `N = 8`).

Frozen segments are no longer eligible for rewrite. This bounds cost and prevents older text from mutating forever.

### Session memory for frozen context

Long sessions cannot afford to ship the full conversation verbatim inside every `/correct` call. Once corrected segments become frozen, iOS may call a separate `POST /memory/update` endpoint with:
- the previous session-memory blob,
- the newly frozen corrected segments,
- the session's `protected_terms`.

The server returns an updated compact memory object plus the highest `turn_order` it covers. The memory is structured for correction work rather than user-facing display — for example:
- `synopsis`
- `stable_facts`
- `entities`
- `open_threads`

Rules:
- Memory is built only from corrected + frozen text, never from partials or still-mutable turns.
- Memory updates are best-effort and off the hot path. If `/memory/update` fails, live correction still works with the bounded recent window alone.
- `/correct` may include the latest `session_memory` alongside the mutable window.
- Recent verbatim turns always outrank session memory if the two conflict.

### Model and prompt strategy

- **Streaming ASR:** Phases 1 and 2 use conservative `keyterms_prompt` only. Phase 4 wires a small set of English-first streaming prompt templates and `UpdateConfiguration` for mid-session `prompt` / `keyterms_prompt` changes. The live prompt stays narrow and instruction-like so we do not trade away turn detection for cleverness.
- **Phase 1 `/correct`:** single-turn cleanup prompt that preserves meaning and protected spellings.
- **Phase 2 `/correct`:** tighter single-turn prompt, prompt-cached, with deterministic server-side safety guards (length deviation, protected-term mutation, schema) and raw fallback on guard failure. Gated by an adversarial eval suite under `server/eval/adversarial/`.
- **Phase 3 `/correct`:** windowed rewrite prompt with explicit examples for self-corrections, structured output, and compact `session_memory` to carry older frozen context forward without replaying the whole transcript.
- Prompt caching is load-bearing from Phase 2 onward — track cache-read vs cache-creation tokens so prompt edits that break cache hit rate are visible.

### Future multilingual path

Multilingual support is valuable but not load-bearing for the first strong version of VoxScribe. Keep the near-term product English-first on `u3-rt-pro`.

Future work may add:
- streaming `language_detection` metadata for correction hints,
- language-aware prompt selection,
- session-level fallback from `u3-rt-pro` to `whisper-rt` when the conversation is confidently outside U3's supported language set.

That fallback is a product-mode change, not a twitchy per-turn heuristic. If we do it, it should happen deliberately after stable evidence and with a clear understanding that Whisper gives up some of U3's prompt/keyterm steering surface.

### Ordering and idempotency

Correction responses may arrive out of order if multiple requests are in flight. iOS tracks a monotonically increasing request id per session and ignores superseded responses.

**Billing note**: AssemblyAI bills on session duration. Always send `Terminate` on Stop.

## Evaluation harness

We need an accuracy harness from the beginning, not after the demo disappoints.

Track at least:
- partial latency,
- corrected-final latency,
- proper-noun accuracy on seeded terms,
- self-correction accuracy once Phase 3 begins,
- manual post-edit rate during dogfooding.

Maintain a small real-voice eval set in the repo and rerun it whenever we change prompt wording, keyterm selection, or correction thresholds.

The Phase 1 implementation lives under `server/eval/`: `run_eval.py` runs each fixture clip through three modes (`baseline`, `keyterms`, `corrected`) and reports per-clip partial/final/correction latency plus seeded-term accuracy against the ≥80% gate. Audio fixtures stay under `server/eval/fixtures/` (gitignored); the committed `server/eval/manifest.json` is the recording spec. See `server/eval/README.md`.

## Design principles

Cross-cutting rules that govern every phase. If a proposal violates one of these, the proposal changes.

1. **The hot path is sacred.** Audio and partial transcripts go iOS ↔ AssemblyAI directly. Nothing we build may add a hop to partials.
2. **Proper nouns buy trust.** A few wrong names can sink the entire demo. Bias the live path toward the words users care about most.
3. **The live prompt stays conservative.** Use `keyterms_prompt` for recognition and reserve heavier cleanup for `/correct`.
4. **Prefer fewer moving parts over theoretical flexibility.** No DB, queue, cache, or audio proxy until the current path is measurably insufficient. A thin provider boundary exists so AAI can be swapped later without touching the rest of the code, but VoxScribe stays single-provider until eval evidence calls for more.
5. **Correction never blocks rendering.** Raw finals appear immediately. Corrected text patches the already-visible row asynchronously.
6. **Append-and-patch, never rebuild.** The transcript tail may mutate, but the list is reconciled intentionally rather than blown away and redrawn.
7. **Structural rewrites must be explicit.** If a correction merges or splits rows, the server must say what it replaces.
8. **Fail safe, never revert.** Network failure, timeout, malformed response, or model weirdness means "keep current state."
9. **Secrets stay server-side.** The iOS binary never contains an AssemblyAI key or an Anthropic key.
10. **Cost is bounded and visible.** Session duration, correction windows, and model usage are all capped and logged.
11. **Test with real voice, not TTS.** Human self-correction behavior is the thing we are actually trying to solve.

## Roadmap

- **Phase 1 (v1, completed)** — core streaming loop, session vocabulary biasing via `keyterms_prompt`, minimal single-turn `/correct`, configurable simulator/device server URL, and an initial eval harness. See `phase1-plan.md`.
- **Phase 2** — stronger single-turn `/correct` gated by an adversarial eval suite; no live-path changes. See `phase2-plan.md`.
- **Phase 3 (hard requirement)** — windowed semantic rewrite in `/correct`, commit points, and structural row replacement using explicit replacement semantics.
- **Phase 4** — polish & live-path enrichment: reconnect, audio session interruptions, streaming prompt templates, mid-session `UpdateConfiguration`, dictation mode, copy/export, editable vocabulary UI, accessibility audit, and observability hardening.
- **Phase 5** — deployment: containerize the server, ship TestFlight, add production safety rails.

## Future additions

- Profile-derived vocabulary packs such as profession or specialty
- Cross-session memory and personalization
- Team and shared vocabulary once there is a real backend

## Conventions

- No API keys in git. `server/.env.example` documents required vars.
- Dev server URL must be configurable:
  - simulator: `127.0.0.1`
  - physical device: LAN IP or tunnel URL
- Prod will be HTTPS.
- Commit messages: imperative mood, about 50 characters for the subject.
