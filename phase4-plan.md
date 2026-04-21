# Phase 4 — Polish & robustness

Rough outline. Task-level breakdown will be filled in when Phase 4 starts.

**Goal**: The app handles real-world edge cases gracefully. Reconnects from dropped Wi-Fi. Survives phone-call interruptions. Costs are observable. Every failure mode has a defined, non-crashing UX.

## Deliverables

### 1. WebSocket reconnection
- Detect drops: `URLSession` error, no message received within N seconds (heartbeat), explicit close from AssemblyAI.
- Reconnect strategy: exponential backoff, up to 3 attempts over ~10 s.
- Mint a fresh token on each reconnect (old token may be expired).
- Audio policy during reconnect: **drop**, don't queue. Mark a visible gap in the transcript ("…" or a faint divider) rather than pretending nothing happened.
- Subtle UI indicator while reconnecting (e.g. mic icon pulses yellow).
- Give up after retries exhausted → surface error, stop session, keep transcript.

### 2. Audio session interruptions
- Listen for `AVAudioSession.interruptionNotification`.
- On interruption begin (phone call, Siri, etc.): pause audio tap, keep WS open (AssemblyAI happily tolerates silence), mark paused in UI.
- On interruption end: resume audio tap (if session was still active).
- Route changes: headphones unplugged, Bluetooth connect/disconnect — re-query input format, adapt converter, continue.
- Background → foreground: if user backgrounded mid-session, we stopped capture; on foreground, stay stopped and let them re-tap Record.

### 3. Editable vocabulary UI
- Settings screen with a text-field list: add/remove terms (names, jargon, product names).
- Terms stored locally (UserDefaults or a simple JSON in Application Support).
- Session vocabulary resolver merges saved terms with the built-in demo seed terms.
- Saved terms feed `keyterms_prompt` on WS connect and, if Phase 2 plumbing exists, can optionally refresh the active session.
- Cap at a practical shortlist and document it.
- Profile-derived packs such as profession or specialty remain future additions, not part of the current Phase 4 scope.

### 4. Observability & cost visibility
- Server logs per-session: duration, turn count, correction calls, Haiku input/output tokens, estimated cost.
- iOS dev-only screen (hidden behind a gesture or build flag): shows current session's stats.
- Log structured JSON (easy to pipe to Axiom / Logtail later).
- No PII in logs — transcript text never leaves the device except for correction, and correction calls are not logged verbatim in production.

### 5. Error taxonomy & UX
Every failure has a defined banner + recovery:
- Mic permission denied → banner → "Open Settings" button.
- Network unreachable → banner → auto-retry when back online.
- AssemblyAI 4xx (invalid token, quota) → error, stop, instruct user to try again.
- AssemblyAI 5xx → reconnect flow.
- Anthropic quota / error → silent; raw stays (principle: correction never blocks).
- Unknown → generic "something went wrong" with a "Report" link.

### 6. Accessibility
- Dynamic Type: transcript body + button labels scale correctly.
- VoiceOver: meaningful labels for Record/Stop, segment states, error banners.
- Color contrast: "muted raw" vs "corrected full" states must remain distinguishable at WCAG AA minimum — don't rely on opacity alone; combine with italic or an unobtrusive icon for the low-vision case.

## Guiding principles (Phase 4 specifics)

- **Every failure has a face.** No crashes. No silent black holes. Every error either recovers silently or tells the user exactly what happened and what to do.
- **Reconnect > replay.** Replaying buffered audio on reconnect adds complexity and breaks turn ordering. A marked gap is honest and simpler.
- **Observability without PII.** We can know session durations, costs, term-hit rates, and error rates without ever logging transcript content. Non-negotiable.
- **Accessibility is not a phase.** But this is the phase where we explicitly audit and fix gaps — retrofits are cheaper than rebuilds.

## Success criteria

- Plane-mode toggle mid-session: app detects drop, reconnects within 10 s of network return, session continues.
- Phone call received mid-session: session pauses, resumes cleanly when call ends.
- AirPods connected/disconnected mid-session: audio continues without session drop.
- Editable vocabulary: add "Anthropic" to saved vocab, start a session, and transcription recognizes it consistently.
- VoiceOver walkthrough of the record → speak → stop → share flow is fully navigable.

## Out of scope

- Multi-device sync (requires auth + backend DB).
- Team / shared transcripts.
- Translation, summarization, any post-session LLM features.
- Multilingual model routing / Whisper fallback. Keep this as a future enhancement after the core English-first product is solid.

## Open questions / risks

- **Silent Anthropic failures masking real correction regressions**: since we fall back to raw, a misconfigured API key or quota hit looks fine. Mitigate with a server-side health check surfaced to the dev dashboard.
- **Route change races**: iOS can fire multiple interruption/route notifications in quick succession. Needs careful state machine — test with BT flapping, headphone replug, etc.
- **Vocabulary UX**: is a flat list enough? Per-session overrides? Future profile packs? Decide after dogfooding.
