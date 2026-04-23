# CLAUDE.md

## Scope

This file covers the server-side correction stack in `server/`.

The most important behavior is not "best rewrite." It is conservative cleanup
with safe fallback to raw text.

The stack has two single-turn correction endpoints:

- `/correct` — prose, owned by `server/correction.py` (Haiku-tier).
- `/correct_code` — Python code, owned by `server/code_correction.py` plus
  deterministic validators in `server/code_validation.py` (Sonnet-tier).

Both fall back to raw on API error, malformed tool output, or safety/validation
failure. Behavioral contracts: `correction-spec.md` (prose) and
`code-mode-spec.md` (code).

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
- Would this change cause `version two` to become `version 2` in standard mode?
- Would this change cause partial emails, phones, URLs, or versions to gain invented missing components?

If the answer might be yes, tighten the prompt or add a safety case first.

## Required Sync Points

Prose correction:

- prompt wording in `server/correction.py`
- behavioral contract in `/Users/omkarpatil/Projects/VoxScribe/correction-spec.md`
- adversarial cases under `server/eval/adversarial/cases/` (01–11)
- payload handling in `server/eval/adversarial/runner.py`

Code correction:

- prompt wording in `server/code_correction.py`
- deterministic checks in `server/code_validation.py`
- behavioral contract in `/Users/omkarpatil/Projects/VoxScribe/code-mode-spec.md`
- adversarial cases under `server/eval/adversarial/cases/12_code_*.json` and `13_code_*.json`
- per-case `endpoint` routing in `server/eval/adversarial/runner.py`

Important: multilingual adversarial cases rely on forwarding per-case
`transcriber` and `detected_language`. Do not remove or bypass that plumbing.
Code cases rely on the per-case `endpoint: "correct_code"` field to reach the
right route.

## Code Mode Rules

When editing `server/code_correction.py` or `server/code_validation.py`:

- keep the endpoint English-Standard-Python only at the schema layer; do not
  soften those guards
- preserve the rule that prose utterances stay prose (do not force identifier
  casing)
- preserve the rule that partial code fragments are not completed from general
  programming knowledge
- preserve self-correction non-resolution in code context
- validation is a safety filter, not a proof of correctness — its job is to
  trigger raw fallback on obvious structural mistakes, not to prove code runs
- do not carry prose-path validators (length drift, protected-term verbatim
  guard) into code validation; identifier reshaping legitimately breaks them

## Eval Guidance

If you add a new prompt rule, add a case for it.

Minimum failure modes that should stay covered:

- protected term mutation
- self-correction resolution in Phase 2
- unsupported specificity upgrades
- dictation command/literal ambiguity
- hallucinated additions on fragments
- translation of code-switched or multilingual content
- invented completion of partial structured data

## Safety Posture

The server should always prefer raw text over a suspect rewrite.

If a change makes outputs prettier but riskier, it is usually the wrong change
for this layer.
