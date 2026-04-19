# Phase 2 — Per-turn correction + dictation + export

Rough outline. Task-level breakdown will be filled in when Phase 2 starts.

**Goal**: Build on the Phase 1 demo path by tightening per-turn correction, enabling dictation commands, supporting dynamic vocabulary updates, and letting users copy/export what they see.

## Deliverables

### 1. Per-turn `/correct` v2
- Provider: Anthropic API, model `claude-haiku-4-5`.
- System prompt (prompt-cached) tightens the Phase 1 cleanup behavior:
  - restore punctuation,
  - truecase proper nouns + sentence starts,
  - remove filler words when clearly filler,
  - fix within-turn false starts,
  - preserve `protected_terms` exactly.
- Output keeps the existing `segments[]` shape.
- Hard constraints in prompt:
  - never add content,
  - never change meaning,
  - never summarize,
  - preserve the speaker's voice.
- Safety checks:
  - if corrected text's length deviates too far from input, fall back to raw;
  - if a protected term disappears or mutates unexpectedly, fall back to raw.
- Window stays single-turn — multi-turn is Phase 3.

### 2. Dynamic vocabulary updates
- Use AssemblyAI `UpdateConfiguration` to refresh `keyterms_prompt` mid-session when the active vocabulary changes.
- Sources for updates:
  - current document or screen context,
  - recent user corrections,
  - explicit session overrides for the demo.
- Keep the live streaming prompt conservative even after adding dynamic keyterms.

### 3. Dictation mode
- UI toggle: Dictation ON / OFF. Default OFF.
- When ON: the correction prompt gets an additional instruction — interpret spoken punctuation words ("period", "comma", "question mark", "new paragraph", "new line") as punctuation rather than literal text.
- Why server-side and not client regex: handles plural/variant forms ("new paragraphs", "new line please") naturally, scales to more commands, keeps client dumb.
- `ForceEndpoint` sent to AssemblyAI whenever a terminal command ("period", "question mark") is detected in a partial — ends the turn promptly rather than waiting for silence.

### 4. Copy / export
- "Copy" toolbar button: concatenates user-visible text (corrected where available, raw fallback), copies plain text to pasteboard.
- "Share" toolbar button: same text via `UIActivityViewController` — save to Files, AirDrop, email, etc.
- No server round-trip for export — everything is already on device.

## Guiding principles (Phase 2 specifics)

- **Per-turn only.** Don't prematurely build window-management machinery; Phase 3 owns that.
- **Dictation lives in the prompt, not the client.** The LLM is already in the loop for correction; overloading it with command interpretation is free.
- **Dynamic keyterms beat a heavier live prompt.** When live accuracy needs help, update `keyterms_prompt` before adding more prompt complexity.
- **Export reflects what the user sees.** If the user is reading corrected text, that's what gets copied. Raw-only fallback is acceptable but the mental model is "copy what I see."
- **No regressions to the 150 ms hot path.** Haiku latency (200–500 ms typical) affects the raw-final → corrected swap, not partial rendering.

## Success criteria

- 30-second real-voice session: finalized turns visibly become "corrected" within ~1 s of the raw final.
- Dynamic vocabulary update: add a new term mid-session and see subsequent live ASR pick it up more reliably.
- Dictation ON: speaking "remind me to buy milk period new paragraph" produces `Remind me to buy milk.\n\n` in the transcript.
- Copy produces the expected text; share sheet works end-to-end.
- No observable partial-latency regression vs Phase 1.
- Per-session Haiku cost measurable and logged.

## Out of scope

- Multi-turn / cross-turn correction (Phase 3).
- User-editable vocabulary settings UI (Phase 4).
- Reconnection, interruption handling (Phase 4).
- Pricing / model tier UI (not required).

## Open questions / risks

- **Haiku latency variance**: p99 could be >1 s. If it noticeably degrades UX, explore streaming the Anthropic response and applying partial corrections as they generate.
- **Dictation command false positives**: e.g. user says "period" as part of a sentence ("during that period..."). The LLM has to infer from context. May need a confidence signal or a "strict mode" where only turn-terminal commands are interpreted.
- **Prompt drift**: as we iterate on prompts and keyterm selection, we need to keep rerunning the eval set or we will regress without noticing.
