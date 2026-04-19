# Phase 3 — Windowed semantic rewrite (hard requirement)

Rough outline. Task-level breakdown will be filled in when Phase 3 starts.

**Goal**: Cross-turn self-corrections resolve automatically. "Let's meet at 2, no actually 3" → "Let's meet at 3." This is the capability that makes VoxScribe worth using over raw AssemblyAI output. Without this, the project is incomplete.

## Deliverables

### 1. Multi-turn windowing
- `/correct` receives an ordered window of recent turns (not just one).
- Window bounded by:
  - Sliding cap: N = 8 turns (configurable).
  - Commit points: inter-turn gap > ~2 s + high `end_of_turn_confidence`, or manual "new paragraph" command.
  - Token safety net: ~600 tokens input.
- Frozen segments (older than commit point / cap) drop out of future windows — immutable thereafter.

### 2. Segment merge / split / delete with explicit replacements
- The server may return fewer, more, or a different number of segments than it received turns for.
- Each returned segment declares its `source_turn_orders` (which input turns it covers).
- Text-only rewrites should preserve the existing `segment.id` whenever possible.
- Structural rewrites create new opaque ids and must declare `replaces_segment_ids`.
- iOS reconciliation is explicit, not inferred:
  - Matched id → update text in place.
  - New id + `replaces_segment_ids` → remove the replaced rows and insert the new one(s) transactionally.
- Protected terms from the current vocabulary revision continue to be passed into every `/correct` call.

### 3. Prompt design for semantic rewrite
- System prompt (prompt-cached) includes:
  - Explicit permission: resolve self-corrections, disfluencies, filler, false starts.
  - Explicit prohibition: no content additions, no summarization, no style/voice changes.
  - Explicit preservation: keep `protected_terms` exactly as provided unless the raw speech clearly corrected the term itself.
  - Few-shot examples: number correction ("2 no 3"), name correction, time correction, phrase replacement ("scratch that, I meant..."), mid-sentence restarts.
  - Structured JSON output: `{"segments": [{"id": "...", "source_turn_orders": [...], "text": "...", "replaces_segment_ids": [...]}]}`.
- Model: `claude-haiku-4-5`. Escalate to Sonnet only if Haiku empirically struggles (probably won't).

### 4. UI: structural changes
- SwiftUI `ForEach` on segments keyed by `segment.id` — diffing engine handles inserts/deletes natively.
- Deletions: row fades out (~200 ms), list shifts up with a spring animation.
- Merges: two rows animate toward each other, text crossfades to merged string.
- Splits: inverse — one row divides, each half crossfades to its new text.
- Acceptance: a user watching a correction should feel "that reorganized naturally," not "the screen jumped."

### 5. Debounce + in-flight supersession
- `/correct` fires 250 ms after the last finalized turn. Bursts collapse into one call.
- Client tags each call with an incrementing request id; late responses whose id < current are dropped.
- On Stop: briefly await (≤1 s) any in-flight correction before tearing down, to let the final rewrite land.

### 6. Safety: detecting over-correction
- On every `/correct` response, run a lightweight diff: if the corrected text's Levenshtein distance from the raw is >60% of raw length, treat as suspect — keep raw.
- Rationale: protects against LLM hallucination or prompt failure rewriting meaning wholesale.
- Log suspects for eval / prompt tuning.

## Guiding principles (Phase 3 specifics)

- **The window is the only mutable surface.** Frozen text never moves. The UI's top scroll region is stable; only the tail dances.
- **Text-only edits should feel stable; structural edits should feel intentional.** Preserve ids when possible and use explicit replacements when the structure changes.
- **Resegmentation is the LLM's job, not the client's.** The client doesn't try to detect self-corrections heuristically — it passes the window and trusts the structured output.
- **Safety over cleverness.** A correction that changes meaning is worse than no correction. Conservative diff thresholds, explicit prompt prohibitions, observable fall-back to raw.
- **Prompt caching is load-bearing.** The system prompt (instructions + examples) is the large part; the window is the small part. Cache the prefix.

## Success criteria

- Scripted real-voice test set (20+ utterances covering number, name, time, and phrase self-corrections): ≥90% resolve correctly, 0% produce hallucinated content.
- No user-visible change in partial latency vs Phase 2 (hot path untouched).
- Sustained 5-minute dictation session: window never exceeds cap, frozen segments never mutate, and structural replacements do not cause list thrash.
- Per-call Haiku cost < $0.002 with prompt cache enabled (validate on real sessions).
- 1-hour session cost projection < $5 (covers our budget).

## Out of scope

- User-driven edits (tap a segment to rewrite manually) — could be Phase 4+.
- Cross-session memory (corrections that span across separate sessions).
- Multi-speaker segmentation.

## Open questions / risks

- **Replacement churn under the LLM's whims**: if the LLM keeps resegmenting equivalent text, even explicit replacements can make the UI dance. Mitigation: server post-processes output to preserve ids for text-only edits and only emit replacements when structure truly changed.
- **Commit point false positives**: a user pauses briefly to think, window commits early, then they say "no actually..." and can't retroactively fix. Mitigation: tune commit-point silence threshold on real data; allow manual "un-commit" via a tap if this becomes a real problem.
- **LLM output schema failures**: malformed JSON, missing fields. Use Anthropic's structured-output / tool-use features to enforce schema at the API level. Fall back to raw on parse failure.
- **Window concurrency at Stop**: if the user stops mid-burst, we may have 1–2 corrections in flight that wanted to rewrite the last segment. The 1 s wait handles the common case; longer stalls should just commit raw.
