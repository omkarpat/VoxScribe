# Phase 4 — Polish, robustness & live-path enrichment

Rough outline. Task-level breakdown will be filled in when Phase 4 starts.

**Goal**: The app handles real-world edge cases gracefully (reconnects from dropped Wi-Fi, survives phone-call interruptions, costs are observable, every failure has a defined non-crashing UX) **and** enriches the live streaming session with the features deferred from Phase 2: streaming prompt templates, mid-session configuration updates, dictation mode, and copy / export.

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

### 3. Streaming prompt templates

- AssemblyAI's streaming WebSocket URL accepts an optional `prompt` query param (see `plan.md` — a short instructional string that biases live formatting, distinct from `keyterms_prompt` and distinct from the `/correct` prompt).
- Add exactly two server-minted templates:
  - **default dictation** — natural conversational formatting,
  - **structured entry** — tuned for emails, phone numbers, and proper names.
- Templates live server-side (`server/providers/assemblyai.py`) and are selected by a `prompt_template` field on `POST /token`.
- No free-form prompt editor in the app — the surface is strictly the two templates.
- Start from AssemblyAI's default turn-detection-friendly behavior; do not invent a prompt that trades turn detection for cleverness.

### 4. `UpdateConfiguration` mid-session updates

- Use AssemblyAI's `UpdateConfiguration` WS message to refresh `keyterms_prompt` and `prompt` mid-session without reconnecting.
- Triggers:
  - active vocabulary revision changes (e.g. new corrections applied),
  - prompt template changes (e.g. dictation toggle in §5),
  - explicit session override from the demo UI.
- Keep the live prompt conservative even after dynamic updates — prefer expanding `keyterms_prompt` before adding prompt complexity.
- Dynamic updates do **not** imply model switching (u3-rt-pro → whisper-rt); that remains Future.

### 5. Dictation mode

- UI toggle: Dictation ON / OFF. Default OFF.
- When ON:
  - select the dictation-oriented streaming prompt template (§3),
  - align the `/correct` prompt to the same behavior.
- Interpret spoken punctuation words ("period", "comma", "question mark", "new paragraph", "new line") as punctuation rather than literal text.
- Why server-side and not client regex: handles plural / variant forms ("new paragraphs", "new line please") naturally, scales to more commands, keeps the client dumb.
- Send `ForceEndpoint` to AssemblyAI when a terminal command ("period", "question mark") is detected in a partial — ends the turn promptly rather than waiting for silence.
- Rerun Phase 2's adversarial eval suite with the dictation prompt variant before shipping.

### 6. Copy / export

- "Copy" toolbar button: concatenates user-visible text (corrected where available, raw fallback), copies plain text to the pasteboard.
- "Share" toolbar button: same text via `UIActivityViewController` — save to Files, AirDrop, email, etc.
- No server round-trip; everything is already on device.
- Mental model: "copy what I see."

### 7. Editable vocabulary UI
- Settings screen with a text-field list: add/remove terms (names, jargon, product names).
- Terms stored locally (UserDefaults or a simple JSON in Application Support).
- Session vocabulary resolver merges saved terms with the built-in demo seed terms.
- Saved terms feed `keyterms_prompt` on WS connect and, if Phase 2 plumbing exists, can optionally refresh the active session.
- Cap at a practical shortlist and document it.
- Profile-derived packs such as profession or specialty remain future additions, not part of the current Phase 4 scope.

### 8. Observability & cost visibility
- Server logs per-session: duration, turn count, correction calls, Haiku input/output tokens, estimated cost.
- iOS dev-only screen (hidden behind a gesture or build flag): shows current session's stats.
- Log structured JSON (easy to pipe to Axiom / Logtail later).
- No PII in logs — transcript text never leaves the device except for correction, and correction calls are not logged verbatim in production.

### 9. Error taxonomy & UX
Every failure has a defined banner + recovery:
- Mic permission denied → banner → "Open Settings" button.
- Network unreachable → banner → auto-retry when back online.
- AssemblyAI 4xx (invalid token, quota) → error, stop, instruct user to try again.
- AssemblyAI 5xx → reconnect flow.
- Anthropic quota / error → silent; raw stays (principle: correction never blocks).
- Unknown → generic "something went wrong" with a "Report" link.

### 10. Accessibility
- Dynamic Type: transcript body + button labels scale correctly.
- VoiceOver: meaningful labels for Record/Stop, segment states, error banners.
- Color contrast: "muted raw" vs "corrected full" states must remain distinguishable at WCAG AA minimum — don't rely on opacity alone; combine with italic or an unobtrusive icon for the low-vision case.

## Guiding principles (Phase 4 specifics)

- **Every failure has a face.** No crashes. No silent black holes. Every error either recovers silently or tells the user exactly what happened and what to do.
- **Reconnect > replay.** Replaying buffered audio on reconnect adds complexity and breaks turn ordering. A marked gap is honest and simpler.
- **Observability without PII.** We can know session durations, costs, term-hit rates, and error rates without ever logging transcript content. Non-negotiable.
- **Accessibility is not a phase.** But this is the phase where we explicitly audit and fix gaps — retrofits are cheaper than rebuilds.
- **Two prompt templates are enough.** Resist prompt sprawl. Phase 4 adds exactly two streaming templates; a free-form prompt UI is explicitly out of scope.
- **Dynamic keyterms beat a heavier live prompt.** When live accuracy needs help, update `keyterms_prompt` via `UpdateConfiguration` before layering on prompt complexity.
- **Dictation lives in the prompt, not the client.** The LLM is already in the loop for correction; overloading it with command interpretation is free and scales to variant forms. The client stays dumb.
- **Export reflects what the user sees.** If the user is reading corrected text, that's what gets copied. Raw-only fallback is acceptable; the mental model is "copy what I see."
- **Phase 2's eval gate still holds.** Any change to the `/correct` prompt that comes in with dictation mode must re-pass Phase 2's adversarial suite before shipping.

## Success criteria

- Plane-mode toggle mid-session: app detects drop, reconnects within 10 s of network return, session continues.
- Phone call received mid-session: session pauses, resumes cleanly when call ends.
- AirPods connected/disconnected mid-session: audio continues without session drop.
- Prompt-template switch (default → structured entry) works at session start and mid-session without reconnecting.
- Adding a new keyterm mid-session via `UpdateConfiguration` makes subsequent live ASR pick it up more reliably.
- Dictation ON: speaking "remind me to buy milk period new paragraph" produces `Remind me to buy milk.\n\n` in the transcript.
- Copy produces the expected text; share sheet works end-to-end.
- No observable partial-latency regression vs Phase 1 after these features land.
- Editable vocabulary: add "Anthropic" to saved vocab, start a session, and transcription recognizes it consistently.
- VoiceOver walkthrough of the record → speak → stop → share flow is fully navigable.

## Out of scope

- Multi-device sync (requires auth + backend DB).
- Team / shared transcripts.
- Translation, summarization, any post-session LLM features.
- Multilingual model routing / Whisper fallback. Keep this as a future enhancement after the core English-first product is solid.
- Free-form prompt authoring UI — two server-minted templates only.
- Mid-session model switching (e.g. u3-rt-pro → whisper-rt). `UpdateConfiguration` in this phase is config-only.

## Open questions / risks

- **Silent Anthropic failures masking real correction regressions**: since we fall back to raw, a misconfigured API key or quota hit looks fine. Mitigate with a server-side health check surfaced to the dev dashboard.
- **Route change races**: iOS can fire multiple interruption/route notifications in quick succession. Needs careful state machine — test with BT flapping, headphone replug, etc.
- **Vocabulary UX**: is a flat list enough? Per-session overrides? Future profile packs? Decide after dogfooding.
- **Prompt drift and turn-detection regressions**: a clever live prompt can quietly damage endpointing. Mitigation: start from AssemblyAI's default prompt behavior, keep only two templates, rerun the eval set whenever prompts change.
- **Dictation command false positives**: e.g. user says "period" as part of a sentence ("during that period…"). The LLM has to infer from context. May need a confidence signal or a strict mode where only turn-terminal commands are interpreted.
