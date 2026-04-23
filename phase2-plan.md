# Phase 2 — `/correct` v2 + adversarial evals

**Goal**: Harden the per-turn correction layer behind an adversarial eval suite that catches the specific ways Haiku can quietly degrade output — hallucinated content, protected-term mutation, meaning drift, unintended self-correction. Phase 2 does **not** change the live streaming path, the WebSocket plumbing, or the client UI in any material way; the whole phase is backend prompt work gated by tests.

## Non-goals (moved to later phases)

- Streaming prompt templates (`prompt` query param wiring) — **Phase 4**
- `UpdateConfiguration` mid-session keyterm / prompt updates — **Phase 4**
- Dictation mode (UI toggle, spoken-punctuation handling, `ForceEndpoint` on terminal commands) — **Phase 4**
- Copy / export toolbar buttons — **Phase 4**
- Multilingual routing / `whisper-rt` fallback — **Future additions** (see `plan.md`)
- Multi-turn or windowed rewrite, cross-turn self-correction — **Phase 3** (also an explicit regression guard in Phase 2's eval suite)

## Deliverables

### 1. `/correct` v2 prompt

- Provider: Anthropic API, `claude-haiku-4-5`.
- System prompt is prompt-cached and tightens Phase 1's cleanup behavior:
  - restore punctuation,
  - truecase proper nouns and sentence starts,
  - remove filler words when clearly filler (um / uh / you know / like-as-filler),
  - fix within-turn false starts,
  - preserve `protected_terms` exactly as provided.
- Hard constraints baked into the prompt:
  - never add content,
  - never change meaning,
  - never summarize,
  - preserve the speaker's voice and register,
  - do **not** resolve cross-turn or within-turn self-corrections — leave "two, no actually three" intact (self-correction is a Phase 3 capability).
- Output preserves Phase 1's `segments[]` shape. No API contract changes.

### 2. Safety guards (server-side, deterministic)

Each `/correct` response is validated before return. Any failure falls back to the raw input for that turn:

- **Length deviation**: if `|len(out) - len(in)| / len(in) > 0.5`, fallback.
- **Protected-term mutation**: every term in `protected_terms` that was present in the input must be present in the output (case-sensitive), else fallback.
- **Schema violation**: malformed JSON, wrong field shape, or wrong segment count for a single-turn input — fallback.

Each fallback is structured-logged with a reason code so the eval harness can track fallback rate per category.

### 3. Adversarial eval suite

New harness under `server/eval/adversarial/`:

- **Case format** (JSON per category):
  - `id`,
  - `input_transcript` (single-turn raw text),
  - `protected_terms`,
  - one or more `assertions` (see below),
  - optional `notes` / `source`.
- **Assertions** — deterministic only, no LLM-as-judge:
  - `contains_exact` / `not_contains` (substring or regex),
  - `protected_terms_preserved` (all listed terms appear verbatim in output),
  - `length_ratio_between` (min, max),
  - `does_not_resolve_self_correction` (input tokens like "two" and "three" both still present in output),
  - `no_added_semantic_content` (no token from `forbidden_additions` appears),
  - `fallback_expected` (case is engineered to trip a safety guard — assertion is that output equals raw input).
- **Categories (initial seed)**:
  1. Protected-term fidelity
  2. Meaning preservation (length + forbidden-substring)
  3. Self-correction regression guard (must **not** resolve in Phase 2)
  4. Filler discipline (filler removed, quoted / intentional filler preserved)
  5. Within-turn false-start cleanup (positive cases)
  6. Hallucination resistance (truncated / garbled input)
  7. Punctuation and casing (positive cases)
  8. Multilingual transliteration without translation
  9. Specificity discipline for product names, code-like tokens, env vars, and version shorthand
  10. Dictation command vs literal-word ambiguity
  11. Structured-text safety for emails, phone numbers, URLs, IDs, and partial fragments
- **Runner**: hits the real `/correct` endpoint (local FastAPI), records pass/fail per case, aggregates per-category pass rate and per-category fallback rate, writes a markdown report.
- **Gates**:
  - Protected-term fidelity: ≥95% pass.
  - Self-correction regression guard: **100%** pass (non-negotiable — self-correction is Phase 3).
  - All other categories: ≥85% pass.
  - Overall fallback rate on positive cases: <5% (high fallback means the prompt is too cautious).
- **Invocation**: `python -m server.eval.adversarial` — single command, prints report, non-zero exit on gate failure.
- **Flakiness control**: each case runs N times (default N=3); pass requires a majority of runs pass. Surfaces Haiku variance without letting it hide.

### 4. Prompt-cache telemetry

- Log cache-read tokens vs cache-creation tokens per `/correct` call.
- Aggregate in the eval runner so prompt edits that break cache hit rate become visible.

## Guiding principles (Phase 2 specifics)

- **The eval suite is the spec.** The prompt is only "done" when the suite passes at the gates. No vibes, no manual spot-checks as proof.
- **Adversarial > representative.** Phase 1's eval measures "does it mostly work." Phase 2's suite measures "does it break in the specific ways we've decided are unacceptable."
- **Deterministic assertions only.** LLM-as-judge creates correlated-failure risk — the grader and the generator share biases. Every assertion is substring / regex / length / set-membership.
- **Self-correction is a Phase 3 capability.** If Phase 2's prompt accidentally resolves "two, no three" → "three", that's a regression to catch, not an early feature to enjoy.
- **Fallback to raw beats clever recovery.** When a safety guard trips, the raw text stays. No second attempt, no partial accept.
- **Structured text stays conservative.** Standard mode may format explicitly spoken separators, but it must not invent missing TLDs, phone digits, URL components, version numbers, env vars, or code identifiers.
- **No live-path changes.** Audio capture, WS lifecycle, and UI stay exactly as Phase 1 shipped. Phase 2 is all backend prompt + tests.

## Success criteria

- Adversarial eval suite passes all category gates.
- Prompt-cache hit rate ≥80% on typical sessions (measured via cache-read / cache-creation tokens).
- Per-session Haiku cost recorded and within budget (target: <$0.30 for a 10-minute session).
- Phase 1's existing `server/eval/run_eval.py` still passes its seeded-term threshold after the prompt change (guards against recognition-path regressions from overlooked interactions).

## Out of scope

- Everything listed under "Non-goals" above.
- Streaming response from Anthropic (if Haiku p99 > 1 s hurts perceived UX, revisit alongside Phase 3's rewrite work).
- LLM-as-judge evaluation.

## Open questions / risks

- **Adversarial coverage gaps**: any hand-authored case suite has blind spots. Mitigation: expand the suite whenever a real-voice regression is observed.
- **Prompt over-fitting to the suite**: a prompt tuned to exactly satisfy these cases can still fail on the next real-voice session. Mitigation: keep a small separate live-voice smoke test that isn't part of the gate.
- **Haiku variance**: a single call can produce different output across runs. Mitigation: N-times repetition with majority-pass (see §3).
- **Fallback-rate vs pass-rate tension**: cautious prompts can push both pass rate and fallback rate up. Mitigation: gate on both.
