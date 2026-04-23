# CLAUDE.md

## Scope

This file covers the server-side correction stack in `server/`.

The most important behavior is not "best rewrite." It is conservative cleanup
with safe fallback to raw text.

## Prompt Editing Rules

When editing `server/correction.py`:

- preserve the single-turn Phase 2 boundary
- preserve the rule that self-corrections are not resolved in Phase 2
- preserve the rule that protected terms must survive exactly
- prefer under-correction to unsupported specificity
- keep multilingual behavior as transliteration, not translation

Do not introduce prompt wording that encourages:

- brand-name guessing
- model/version expansion from shorthand
- canonicalization of code-like tokens without evidence
- completion of partial structured fields
- rewriting speech into notes or summaries

## Specificity Discipline Checklist

Before shipping a prompt change, sanity-check these questions:

- Would this change cause `haiku` to become `Claude Haiku` without explicit raw support?
- Would this change correctly allow `read me` to become `README` while still blocking `README.md` without explicit raw support?
- Would this change cause `api key` to become an env var or identifier?
- Would this change cause partial emails, URLs, or versions to be completed?

If the answer might be yes, tighten the prompt or add a safety case first.

## Required Sync Points

Keep these aligned:

- prompt wording in `server/correction.py`
- behavioral contract in `/Users/omkarpatil/Projects/VoxScribe/correction-spec.md`
- adversarial cases under `server/eval/adversarial/cases/`
- payload handling in `server/eval/adversarial/runner.py`

Important: multilingual adversarial cases rely on forwarding per-case
`transcriber` and `detected_language`. Do not remove or bypass that plumbing.

## Eval Guidance

If you add a new prompt rule, add a case for it.

Minimum failure modes that should stay covered:

- protected term mutation
- self-correction resolution in Phase 2
- unsupported specificity upgrades
- dictation command/literal ambiguity
- hallucinated additions on fragments
- translation of code-switched or multilingual content
- normalization of partial structured data

## Safety Posture

The server should always prefer raw text over a suspect rewrite.

If a change makes outputs prettier but riskier, it is usually the wrong change
for this layer.
