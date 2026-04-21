# Correction Spec

## Correction Goals

`/correct` is a conservative post-ASR editor for VoxScribe. It improves transcript quality after ASR without touching the audio hot path.

Goals:
- Preserve meaning exactly.
- Improve readability through punctuation, casing, and light cleanup.
- Preserve protected terms exactly.
- Improve note-taking usefulness without inventing content.
- Keep failures safe: if correction is uncertain or malformed, raw text stays visible.

Non-goals:
- Recover missing acoustic information.
- Translate speech.
- Summarize content.
- Invent names, numbers, dates, or entities not strongly supported by text context.
- Perform diarization.

Core rules:
- Prefer minimal edits over broad rewrites.
- If uncertain, preserve the raw wording.
- Recent verbatim turns outrank inferred context.
- Phase 2 is single-turn only.
- Phase 3 owns semantic rewrite across turns.

## Phase 2 Contract

Phase 2 is a single-turn cleanup layer.

Allowed behaviors:
- Restore punctuation and sentence boundaries.
- Restore casing and truecasing.
- Remove obvious filler words when clearly non-meaningful.
- Clean harmless repeated words or false starts when meaning does not change.
- Preserve `protected_terms` exactly.
- Support dictation semantics in a dedicated profile.
- Support structured-entry normalization in a dedicated profile.

Disallowed behaviors:
- Resolve self-corrections into a final meaning.
- Merge, split, or delete transcript rows.
- Rewrite across multiple turns.
- Paraphrase for style.
- Translate code-switched or non-English text.

Profiles:
- `default`: punctuation, casing, filler cleanup, protected-term preservation.
- `dictation`: `default` plus spoken punctuation and line/paragraph commands.
- `structured_entry`: `default` plus normalization of emails, phone numbers, URLs, IDs, and similar structured content when strongly supported.

Phase 2 request shape:

```json
{
  "session_id": "string",
  "vocabulary_revision": 1,
  "protected_terms": ["VoxScribe", "AssemblyAI"],
  "profile": "default",
  "turns": [
    { "turn_order": 12, "transcript": "raw asr text" }
  ]
}
```

Phase 2 response shape:

```json
{
  "segments": [
    {
      "id": "turn-12",
      "source_turn_orders": [12],
      "text": "Raw ASR text, cleaned."
    }
  ]
}
```

## Phase 3 Contract

Phase 3 is a bounded semantic rewrite layer over a small mutable window.

Allowed behaviors:
- Resolve self-corrections across turns.
- Resolve "no actually", "scratch that", "I meant", and similar overrides.
- Merge, split, or delete rows when needed.
- Use rolling session memory for older frozen context.
- Preserve recent mutable turns as the authoritative source of truth.

Disallowed behaviors:
- Rewrite frozen text outside the active window.
- Use session memory to override the current raw window.
- Summarize instead of correcting.
- Invent unsupported details.

Phase 3 request shape:

```json
{
  "session_id": "string",
  "vocabulary_revision": 4,
  "protected_terms": ["VoxScribe", "AssemblyAI"],
  "profile": "semantic_rewrite",
  "session_memory": {
    "synopsis": "short context",
    "stable_facts": ["..."],
    "entities": ["..."],
    "open_threads": ["..."]
  },
  "turns": [
    { "turn_order": 21, "transcript": "lets meet at 2" },
    { "turn_order": 22, "transcript": "no actually 3" }
  ]
}
```

Phase 3 response shape:

```json
{
  "segments": [
    {
      "id": "seg-0007",
      "source_turn_orders": [21, 22],
      "text": "Let's meet at 3.",
      "replaces_segment_ids": ["turn-21", "turn-22"]
    }
  ]
}
```

Session memory rules:
- Built only from corrected, frozen text.
- Never built from partials.
- Kept small and structured.
- Used as context, not truth.
- Recommended fields: `synopsis`, `stable_facts`, `entities`, `open_threads`.

## Prompt Rules

Role:
- Claude acts as a conservative ASR correction editor for an AI note-taking app.

Allowed edits:
- Punctuation and casing repair.
- Truecasing of clear proper nouns and protected terms.
- Obvious filler removal.
- Harmless repetition cleanup.
- Dictation command interpretation in `dictation`.
- Structured normalization in `structured_entry`.
- Self-correction resolution only in `semantic_rewrite`.

Forbidden edits:
- Summarization.
- Translation.
- Style paraphrasing.
- Synonym substitution unless clearly required to fix an ASR error.
- Inventing missing content.
- Changing uncertain names, numbers, dates, or entities without strong support.

Uncertainty policy:
- If multiple outputs are plausible, keep the raw text.
- If memory conflicts with the current raw window, trust the current raw window.

Structured output policy:
- Use forced Claude tool calling instead of free-form text parsing.
- Phase 2 tool: `submit_single_turn_correction` with `cleaned_text`.
- Phase 3 tool: `submit_windowed_correction` with `segments[]`.
- Force a single named tool and disable parallel tool use.

## Safety and Fallbacks

Safety checks:
- If a protected term appears in the raw text, it must appear exactly in corrected output.
- If output length drifts too far from input, fall back to raw.
- If output adds unsupported content, fall back to raw.
- If Phase 2 tries to resolve self-correction meaning, fall back to raw.
- If structured output is missing required fields, fall back to raw.
- If the model returns malformed or semantically invalid structure, fall back to raw.

Operational rule:
- Correction failure never clears or removes visible transcript text.
- Raw text remains the safe default on timeout, parse failure, schema failure, or suspect rewrite.

## Eval Spec

`/correct` should have a committed text-only benchmark. It does not require audio.

Dataset composition:
- Curated gold cases.
- Deterministic noisy-ASR variants derived from clean references.
- Adversarial safety cases.

Phase 2 eval categories:
- Punctuation restoration.
- Sentence-boundary repair.
- Casing and truecasing.
- Acronym preservation.
- Protected terms.
- Rare names and product names.
- Filler removal.
- Harmless repetition cleanup.
- No-change stability.
- Code-switching preservation.
- No-translation behavior.
- Negation preservation.
- Dates, times, and numbers.
- Dictation commands.
- Structured-entry normalization for emails, phone numbers, URLs, IDs, and versions.

Phase 3 eval categories:
- Cross-turn number correction.
- Cross-turn time correction.
- Name correction across turns.
- Phrase replacement.
- Quantity correction.
- Scratch-that overrides.
- Three-turn override cases.
- Session-memory continuity cases.
- Structural replacement correctness.

Metrics:
- Exact-match rate on runnable gold cases.
- Protected-term preservation rate.
- No-change stability rate.
- No-translation safety rate on code-switching cases.
- Forbidden-edit rate.
- Phase 3 structural accuracy.
- Phase 3 semantic-resolution accuracy.
- Hallucination / over-correction rate.

Recommended gates:
- `100%` protected-term preservation on runnable cases.
- `100%` no-translation preservation on code-switching safety cases.
- `>= 98%` no-change stability.
- `0%` hallucinated additions on gold cases.
- High exact-match rate on current-phase curated cases.

Decision boundary:
- If the edit can be decided from one turn alone without changing meaning, it belongs in Phase 2.
- If the edit requires deciding what the speaker finally meant across turns, it belongs in Phase 3.
- If the edit changes transcript structure, it belongs in Phase 3.

