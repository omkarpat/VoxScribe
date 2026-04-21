# Phase 2 — Per-turn correction + dictation + export

Rough outline. Task-level breakdown will be filled in when Phase 2 starts.

**Goal**: Build on the Phase 1 demo path by tightening per-turn correction, enabling dictation commands, supporting dynamic vocabulary updates, and letting users copy/export what they see. Phase 2 stays English-first; multilingual model routing remains a future enhancement.

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
- Phase 2 goal is to make these edits smaller and more deterministic by pushing more formatting/context work into AssemblyAI upstream.

### 2. Limited streaming prompting
- Add an optional `prompt` parameter to `StreamingClient.open(...)`.
- Support exactly two prompt templates in Phase 2:
  - default dictation,
  - structured-entry mode for things like emails, phone numbers, and names.
- When customizing the live prompt, build off AssemblyAI's default turn-detection-friendly rules rather than inventing a prompt from scratch.
- No free-form prompt editor or arbitrary prompt generation in Phase 2.

### 3. Dynamic streaming configuration updates
- Use AssemblyAI `UpdateConfiguration` to refresh `keyterms_prompt` and `prompt` mid-session when the active vocabulary or prompt mode changes.
- Sources for updates:
  - current document or screen context,
  - recent user corrections,
  - explicit session overrides for the demo.
- Keep the live streaming prompt conservative even after adding dynamic keyterms or prompt switching.

### 4. Dictation mode
- UI toggle: Dictation ON / OFF. Default OFF.
- When ON: select the dictation-oriented streaming prompt template and keep the correction prompt aligned with the same behavior.
- Interpret spoken punctuation words ("period", "comma", "question mark", "new paragraph", "new line") as punctuation rather than literal text.
- Why server-side and not client regex: handles plural/variant forms ("new paragraphs", "new line please") naturally, scales to more commands, keeps client dumb.
- `ForceEndpoint` sent to AssemblyAI whenever a terminal command ("period", "question mark") is detected in a partial — ends the turn promptly rather than waiting for silence.

### 5. Copy / export
- "Copy" toolbar button: concatenates user-visible text (corrected where available, raw fallback), copies plain text to pasteboard.
- "Share" toolbar button: same text via `UIActivityViewController` — save to Files, AirDrop, email, etc.
- No server round-trip for export — everything is already on device.

## Guiding principles (Phase 2 specifics)

- **Per-turn only.** Don't prematurely build window-management machinery; Phase 3 owns that.
- **Dictation lives in the prompt, not the client.** The LLM is already in the loop for correction; overloading it with command interpretation is free.
- **Use AssemblyAI upstream for deterministic shaping.** Prompt templates and mid-stream `UpdateConfiguration` should absorb easy formatting/context work before we ask Haiku to fix anything.
- **Two prompt templates are enough.** Resist prompt sprawl; Phase 2 needs constrained modes, not a prompt-design playground.
- **Dynamic keyterms beat a heavier live prompt.** When live accuracy needs help, update `keyterms_prompt` before adding more prompt complexity.
- **Haiku is not the long-term home for formatting glue.** The more AssemblyAI can handle punctuation, language framing, and structured-entry behavior upstream, the more Haiku can narrow toward semantic cleanup in Phase 3.
- **Multilingual routing is future work.** Language detection, whisper fallback, and multilingual prompt policy are valuable but not on the critical path for the first strong product.
- **Export reflects what the user sees.** If the user is reading corrected text, that's what gets copied. Raw-only fallback is acceptable but the mental model is "copy what I see."
- **No regressions to the 150 ms hot path.** Haiku latency (200–500 ms typical) affects the raw-final → corrected swap, not partial rendering.

## Success criteria

- 30-second real-voice session: finalized turns visibly become "corrected" within ~1 s of the raw final.
- Prompt mode switch mid-session updates the streaming config without reconnecting.
- Dynamic vocabulary update: add a new term mid-session and see subsequent live ASR pick it up more reliably.
- Dictation ON: speaking "remind me to buy milk period new paragraph" produces `Remind me to buy milk.\n\n` in the transcript.
- Copy produces the expected text; share sheet works end-to-end.
- No observable partial-latency regression vs Phase 1.
- Per-session Haiku cost measurable and logged.

## Out of scope

- Multi-turn / cross-turn correction (Phase 3).
- Rolling session memory for frozen context (Phase 3).
- Multilingual support and language-driven model fallback (`u3-rt-pro` → `whisper-rt`).
- User-editable vocabulary settings UI (Phase 4).
- Reconnection, interruption handling (Phase 4).
- Pricing / model tier UI (not required).
- Free-form prompt authoring UI (not required).

## Open questions / risks

- **Haiku latency variance**: p99 could be >1 s. If it noticeably degrades UX, explore streaming the Anthropic response and applying partial corrections as they generate.
- **Dictation command false positives**: e.g. user says "period" as part of a sentence ("during that period..."). The LLM has to infer from context. May need a confidence signal or a "strict mode" where only turn-terminal commands are interpreted.
- **Prompt drift / turn-detection regressions**: a clever live prompt can quietly damage endpointing. Mitigation: start from AssemblyAI's default prompt behavior, keep only two templates, and rerun the eval set whenever prompts change.
