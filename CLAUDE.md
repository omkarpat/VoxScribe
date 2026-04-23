# CLAUDE.md

## Purpose

This repo is an iOS streaming dictation demo with a FastAPI correction service.
The correction layer is intentionally conservative: it should improve readability
without inventing meaning or over-correcting ASR output.

## Source Of Truth

When changing the correction behavior, keep these files in sync:

- `server/correction.py`
- `correction-spec.md`
- `server/eval/adversarial/cases/*.json`
- `server/eval/adversarial/runner.py`

If one of those changes materially and the others do not, the repo is probably
drifting.

## Correction Contract

`/correct` is a single-turn Phase 2 cleanup pass.

Allowed behavior:

- punctuation and sentence-boundary repair
- truecasing of clear proper nouns
- protected-term preservation
- obvious filler removal
- harmless repetition and false-start cleanup
- dictation command handling in `dictation`
- structured-text normalization (emails, phone numbers, URLs, numeric IDs) within `default` only when every required component is present

Disallowed behavior:

- resolving self-corrections into final meaning
- summarizing or paraphrasing for style
- translating code-switched or non-English content
- inventing names, dates, numbers, entities, or missing structured fields
- rewriting across multiple turns

## Specificity Discipline

Prefer under-correction to unsupported specificity.

Important rule: if raw ASR text is vague, keep it vague.

Do not upgrade a token into a more specific brand, model family, version,
filename, identifier, env var, email address, URL, or code symbol unless that
extra specificity is explicitly supported by the raw turn or by
`protected_terms`.

Treat uncommon, code-like, brand-like, and mixed alphanumeric tokens as opaque
by default. A plausible canonical form is still a guess.

Examples of behavior we want:

- keep `haiku` as `haiku` unless the raw text or protected terms clearly support
  `Claude Haiku`
- repair `read me` to `README` when the raw text clearly refers to the common
  file/document token, but do not jump further to `README.md` without support
- keep spoken `api key` as prose unless the raw text clearly supports a code
  identifier such as `OPENAI_API_KEY`
- keep spoken versions such as `version two` as prose in standard mode; version
  shorthand belongs in Code mode
- keep partial structured data incomplete instead of adding missing components
  from product knowledge

## Structured Text Rule

`default` normalizes structured tokens only when every required piece is
present in the single turn.

Normalize only when strongly supported:

- complete email addresses
- complete phone numbers
- complete URLs
- complete numeric IDs

If the input is partial, ambiguous, or code-specific version shorthand, do not
add missing components. Formatting explicitly spoken separators is okay.

The separate `structured_entry` profile has been retired. The server still
accepts it as a deprecated alias of `default` for one compatibility window.

## Eval Expectations

Prompt changes are not done until the adversarial suite is updated or verified.

Key Phase 2 adversarial categories include:

- protected terms
- meaning preservation
- self-correction non-resolution
- filler discipline
- false starts
- hallucination resistance
- punctuation and casing
- multilingual transliteration without translation
- specificity discipline
- dictation command vs literal-word ambiguity
- structured-text partial-field safety under `default`

## Practical Rule For Future Edits

If you change prompt wording to make the model "smarter," add or update cases
that prove it does not become more specific than the raw ASR supports.
