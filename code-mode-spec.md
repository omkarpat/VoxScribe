# Code Mode Spec

## Summary

Remove the existing `structured` correction mode as a separate user-visible
mode.

Split its future in two directions:

- fold the useful `structured` normalization behavior into `Standard` mode as
  table-stakes prose correction
- add a new `code` mode that is optimized for users speaking into an editor

At launch, `code` mode supports exactly one language: `python`.

Unlike prose correction, Code mode should use a separate server endpoint with a
dedicated prompt and a deterministic validation pass before returning text to
the client.

The product surface should be future-ready for additional languages later, but
the initial UI should stay simple: selecting Code mode puts the session into
Python-aware correction behavior without introducing a multi-language picker.

## Why

The current `structured` mode is optimized for emails, phone numbers, URLs, and
other structured text-entry cases. Those behaviors are still useful, but they
should not require a separate mode. They are table stakes for modern correction
and should be folded into `Standard`.

What remains missing is a true editor-oriented mode. That is why the right new
product primitive is `code`.

Editor use has a different set of needs:

- code identifiers are style-sensitive
- punctuation and symbols are semantically meaningful
- casing carries meaning
- comments and docstrings are mixed with code
- over-correction can silently change program behavior

So the product change is not "Structured becomes Code."

It is:

- `Standard` absorbs former structured-entry conveniences
- `Code` is added as a genuinely distinct mode with language-specific
  conventions

## Goals

- Replace `structured` with `code` in the user-visible mode model.
- Fold former `structured` normalization behavior into `Standard`.
- Introduce a separate code-correction endpoint rather than overloading the
  existing prose `/correct` endpoint.
- Make code correction aware of Python naming and formatting conventions.
- Support mixed editor utterances: code, comments, and docstrings.
- Preserve meaning exactly and keep current safety posture.
- Add a deterministic validation step before code-corrected text is returned.
- Keep the launch UI simple by supporting only Python initially.
- Restrict launch scope to English-only Code mode.
- Leave room to add future languages like TypeScript without redesigning the
  whole stack.

## Non-goals

- Full code generation from natural language.
- AST-aware refactoring or semantic editing.
- Multi-line indentation synthesis beyond what is explicitly dictated.
- Auto-completing imports, types, decorators, arguments, or implementation
  details not supported by the raw utterance.
- Project-specific style inference beyond the base Python conventions.
- Broad multi-language support in v1 of Code mode.

## Background Research

This spec is grounded in the official Python docs and style guidance:

- PEP 8 recommends:
  - modules as short lowercase names, with underscores allowed for readability
  - class names in `CapWords`
  - function and variable names in `lowercase_with_underscores`
  - method names and instance variables following function naming rules
  - constants in `UPPER_CASE_WITH_UNDERSCORES`
  - `self` for instance methods and `cls` for class methods
  - a trailing underscore for identifiers that would otherwise collide with a
    reserved keyword
- The Python lexical reference defines identifiers as case-sensitive names made
  from letters, underscores, and non-leading digits, and also defines reserved
  keywords and soft keywords.
- PEP 257 defines Python docstring conventions, including triple double quotes
  and the distinction between one-line and multi-line docstrings.

These sources matter because Code mode should not invent its own "Python-like"
style. It should follow the actual language ecosystem defaults.

## Product Proposal

### User-facing mode model

Replace:

- `Standard`
- `Dictation`
- `Structured`

With:

- `Standard`
- `Dictation`
- `Code`

Important interpretation:

- `Standard` now includes the former structured-entry conveniences when strongly
  supported
- `Code` is not a renamed `Structured`; it is a new editor-focused mode

### Code mode meaning

Code mode means:

- the user is likely dictating into an editor
- the output may contain code, comments, and docstrings
- correction should prefer Python code conventions when the utterance is
  clearly code-like
- correction should avoid forcing code syntax onto plainly prose-like utterances

### Language selection

The long-term model should support a language selection under Code mode.

However, to keep the initial UI simple, v1 should support only Python:

- When `mode == code`, the effective code language is `python`.
- The settings UI may show a non-editable informational row such as
  `Language: Python` with helper text like `More languages later`.
- Do not add a picker until a second language actually exists.

This gives us a stable backend/data model without introducing a fake choice in
the UI.

## UX Spec

### Settings screen

Current mode picker:

- `Standard`
- `Dictation`
- `Structured`

Proposed mode picker:

- `Standard`
- `Dictation`
- `Code`

Proposed Standard-mode footer text:

`General writing mode. Handles punctuation, casing, light cleanup, and common structured text like emails, phone numbers, URLs, IDs, and proper names when strongly supported.`

Proposed Code-mode footer text:

`Optimized for editor use. Applies Python naming and symbol conventions to code-like utterances while keeping prose comments and docstrings readable.`

When Code mode is selected, show an additional row or footer note:

- `Language: Python`
- Helper text: `Python is the only supported code language right now.`

### Transcriber interaction

Initial recommendation: support Code mode only with the English `standard`
transcriber.

Rationale:

- current keyterm support exists only in `standard`
- coding identifiers benefit heavily from protected terms and project vocabulary
- multilingual transliteration is more likely to harm Python symbol fidelity
- a separate English-only path keeps the prompt and validation logic sharply
  focused

Recommended UX behavior:

- If the user selects `multilingual`, hide or disable `Code`
  with an explanation such as `Code mode currently supports English Standard transcriber only.`

This is a product simplification, not a permanent architectural limitation.

### Keyterms behavior

Keep the existing keyterms list.

In Code mode, keyterms become even more important:

- project names
- class names
- internal module names
- framework-specific identifiers
- domain terms that should survive exactly

No separate "code dictionary" surface is needed in v1.

## API / Data Model Spec

### Endpoint split

Do not implement Code mode as another value on the prose `/correct` endpoint.

Recommended architecture:

- `POST /correct`
  - remains the prose endpoint
  - owns `default` and `dictation`
  - `default` absorbs former `structured_entry` normalization behavior
- `POST /correct_code`
  - new dedicated code endpoint
  - owns Python-specific prompting and validation

Why a separate endpoint is the better boundary:

- it keeps prose and code prompts isolated
- it allows code-only validation without complicating prose correction
- it keeps the server contract easier to reason about
- it avoids turning `CorrectionProfile` into a dumping ground for unrelated
  behaviors
- it makes English-only launch restrictions explicit at the API boundary
- it allows an independent model choice for code correction without affecting
  prose correction latency/cost
- it prevents code-specific logic from muddying the now-more-capable standard
  prose path

### Request shape

Proposed `POST /correct_code` request:

```json
{
  "session_id": "string",
  "vocabulary_revision": 12,
  "protected_terms": ["FastAPI", "SQLAlchemy"],
  "code_language": "python",
  "transcriber": "standard",
  "detected_language": "en",
  "turns": [
    {
      "turn_order": 41,
      "transcript": "def get user by id self user id"
    }
  ]
}
```

Proposed contract:

- `code_language` is required
- launch enum contains exactly one value: `python`
- `transcriber` must be `standard`
- `detected_language`, if present, must be `en`
- requests with `multilingual` or non-English language detection should be
  rejected with a clear 4xx error rather than silently degraded
- launch behavior stays single-turn, matching current Phase 2 correction

### Response shape

Recommended response shape:

```json
{
  "segments": [
    {
      "id": "turn-41",
      "source_turn_orders": [41],
      "text": "def get_user_by_id(self, user_id):"
    }
  ],
  "validation": {
    "status": "passed",
    "kind": "code_header",
    "checks": [
      "delimiter_balance",
      "newline_normalization",
      "indentation_consistency",
      "python_snippet_policy"
    ]
  }
}
```

The `validation` object is optional for the client UI, but strongly recommended
for observability and eval reporting.

### Validation pipeline

Code mode should add a deterministic validation phase after the model produces a
candidate output.

Recommended pipeline:

1. Generate candidate text with a Python-focused prompt.
2. Classify the candidate into a small set of snippet kinds:
   - `code`
   - `code_header`
   - `comment`
   - `docstring`
   - `mixed`
3. Run deterministic validators based on snippet kind.
4. If validation passes, return the candidate.
5. If validation fails, optionally run one narrow repair pass informed by the
   validator errors.
6. If repair still fails, fall back to raw text.

### Model strategy

Code mode should not be hard-wired to the same model choice as prose
correction.

Separate endpoint architecture gives us permission to pick a model tier that is
better suited to editor use.

Recommended launch options:

1. Simpler launch:
   - use a Sonnet-tier model as the primary generator for `/correct_code`
   - run deterministic validation afterward
   - fall back to raw on failure

2. Cost-optimized launch:
   - use a Haiku-tier model first
   - validate deterministically
   - escalate to a Sonnet-tier repair pass only on validation failure or other
     high-risk conditions

Recommendation:

- For v1 of Code mode, prefer a Sonnet-tier primary model rather than pure
  Haiku.

Rationale:

- code correction is less tolerant of subtle mistakes than prose cleanup
- naming/style decisions in code are more brittle
- editor users are likely to accept somewhat higher latency in exchange for
  better correctness
- Code mode is a narrower, likely lower-volume surface than general `/correct`

If cost or latency becomes a problem later, the endpoint can evolve to a
Haiku-first / Sonnet-escalation strategy without changing the product surface.

### Deterministic validation checks

The point of validation is not to prove semantic correctness. It is to catch
obvious formatting and structural mistakes cheaply and reliably.

Recommended launch checks:

- balanced delimiters and quotes where snippet kind requires them
- normalized newline handling
- indentation consistency
- snippet-kind-specific Python checks

Do not carry over prose-path checks like protected-term preservation or length
drift as hard validators for Code mode.

Rationale:

- code snippets often compress or expand text non-linearly
- code correction may legitimately convert spoken words into symbols
- identifier reshaping makes raw-vs-output length a poor proxy for safety
- project vocabulary is still useful as prompt context, but it should not be a
  blocking validator in v1

Tabs should also not be categorically forbidden.

Code mode is an editor-oriented keyboard surface, so the model may legitimately
produce indentation. Validation should care about indentation consistency, not
about banning tab characters outright.

Trailing whitespace should not be a hard validation failure in v1 either. At
most, it can be a soft normalization pass if we later decide that is useful.

### Python snippet-kind validation

Because many dictated code turns are fragments, validation cannot be
`ast.parse(candidate)` for every output. It should be kind-aware.

Recommended launch policy:

- `code`
  - if the output looks like a complete standalone statement or expression,
    validate with Python parsing
- `code_header`
  - allow incomplete-but-structural headers such as `def ...:`,
    `class ...:`, `if ...:`, `for ...:`, `while ...:`, `with ...:`
  - validate with targeted structural checks rather than full parsing
- `comment`
  - skip syntax parsing
  - run whitespace and token checks only
- `docstring`
  - validate quote structure and basic formatting
- `mixed`
  - apply conservative checks only; do not force full syntax validity

This separation is a major reason to keep Code mode on its own endpoint.

### Indentation policy

Indentation validation should be conservative and editor-friendly.

Recommended launch policy:

- allow spaces for indentation
- allow tabs for indentation
- do not reject a snippet solely because it contains tabs
- reject obviously inconsistent indentation when deterministically detectable,
  especially mixed tabs/spaces within the same indentation block
- do not attempt full block-indentation validation for single-line fragments

This keeps the validator aligned with the product goal: help the user enter code
into an editor, not enforce a formatter's opinion at the keyboard boundary.

### Validation examples

Pass:

- `def get_user_by_id(self, user_id):`
  - valid as a header fragment
- `cache_key = None`
  - valid as a parseable statement
- `"""Return the active user."""`
  - valid as a docstring snippet
- `\treturn cache_key`
  - acceptable as an indented line fragment if indentation is otherwise
    consistent

Fail:

- `def get_user_by_id(self user_id):`
  - missing comma in a code header
- `def get_user_by_id(self, user_id`
  - unbalanced delimiters / incomplete header structure
- a multi-line snippet that mixes tab and space indentation in the same block
  - inconsistent indentation
- `cache_key == None` when the raw utterance clearly dictated assignment
  - semantic mismatch, if deterministically detectable from spoken operator
- `README.md` introduced from an utterance that only supports `read me`
  - unsupported specificity

### Backwards compatibility

Recommended migration strategy:

1. iOS migrates any persisted `structured` preference to `standard`.
2. Server folds former `structured_entry` logic into the primary `default`
   prose behavior.
3. Server removes `structured_entry` from the primary product contract.
4. Server introduces `POST /correct_code` as a separate launch path.
5. For one compatibility window, the server may accept `structured_entry` as an
   alias of `default` and log a deprecation warning.

Do not alias `structured_entry` to `code`; that would silently reinterpret old
client behavior. Old Structured users were asking for better prose/form-entry
correction, not for editor mode.

## Correction Behavior Spec

## High-level rule

Code mode is still a conservative correction layer, not a code generator.

Its job is to:

- clean up code-like utterances
- normalize Python naming conventions when strongly supported
- infer common Python punctuation and lightweight structure when strongly
  supported by code-like context
- restore symbols and casing when clearly indicated
- preserve uncertain tokens rather than guessing

## Input types within Code mode

Code mode should handle three common utterance types:

1. Code utterances
   Example: `def get user by id self user id`

2. Comment / prose utterances
   Example: `comment this handles cache misses`

3. Docstring utterances
   Example: `triple quote return the active user triple quote`

The model should not force all three into the same shape.

## Allowed behaviors

### Python naming normalization

When strongly supported by the raw utterance and surrounding code markers:

- functions / local variables / parameters / methods:
  - prefer `snake_case`
- classes:
  - prefer `CapWords`
- module-level constants:
  - prefer `UPPER_SNAKE_CASE`
- instance and class method first parameters:
  - prefer `self` and `cls`
- Python keywords:
  - preserve exact lowercase forms like `def`, `class`, `if`, `else`, `for`
- Python built-in constants:
  - preserve exact casing for `True`, `False`, and `None`

### Implicit punctuation and structure inference

In Code mode, users should not have to dictate every punctuation token
explicitly for common Python patterns.

Recommended launch behavior:

- infer `()` and `:` for obvious function and class headers
- infer comma-separated parameter boundaries when the pattern is structurally
  clear
- infer `_` within identifiers when code context strongly supports an
  identifier rather than prose
- treat explicit symbol words as optional disambiguators, not required input

Examples:

- `def get user by id self user id`
  -> `def get_user_by_id(self, user_id):`
- `class user profile base model`
  -> `class UserProfile(BaseModel):`
- `if user is none`
  -> `if user is None:`

### Symbol normalization

When clearly dictated or strongly implied by code context, normalize common
Python symbols such as:

- `(` `)`
- `[` `]`
- `{` `}`
- `:`
- `,`
- `.`
- `_`
- `__`
- `=`
- `==`
- `!=`
- `->`
- `*`
- `**`
- `@`

### Comment and docstring cleanup

For explicitly comment-like or docstring-like speech:

- comments may remain readable prose
- docstrings should prefer Python docstring conventions
- when a docstring is clearly intended, prefer triple double quotes

### Canonical token repair

Canonical token repair is allowed when it preserves the same meaning and token:

- `user id` -> `user_id` when clearly functioning as an identifier
- `dunder init` -> `__init__` when clearly intended
- `none` -> `None` in Python code context

### Spoken symbol words

Spoken symbol words should still be supported, but they should be treated as a
fallback path for disambiguation rather than the primary interaction model.

Good uses:

- disambiguating complex signatures
- expressing operators that are hard to infer from word order alone
- entering less common constructs

Examples:

- `def get user by id open paren self comma user id close paren colon`
- `value double equals none`
- `items open bracket zero close bracket`

## Forbidden behaviors

- inventing imports, module paths, class hierarchies, decorators, type names,
  literals, default values, or implementation details
- completing partial code from general programming knowledge
- rewriting prose requests into executable code
- changing one valid identifier into a more famous Python identifier without
  support
- changing semantics to make code "more Pythonic"
- resolving self-corrections in Phase 2
- reflowing multi-line code structure based on guesswork

## Ambiguity policy

When multiple outputs are plausible:

- keep the raw wording
- preserve unknown identifiers
- do not guess whether a token should be `snake_case`, `CapWords`, or
  `UPPER_SNAKE_CASE` unless syntax context makes the role clear

Examples:

- `haiku client` should not become `HaikuClient` unless the utterance is
  clearly a class definition or protected terms support it
- `requests session` should not become `requests.Session` unless the raw text
  explicitly supports attribute access
- `class` used as prose should not become `class_`

## Python convention table

| Concept | Preferred output in Code mode |
|---|---|
| Module/package name | lowercase, underscores allowed when clearly needed |
| Function / variable / method | `snake_case` |
| Class | `CapWords` |
| Constant | `UPPER_SNAKE_CASE` |
| Instance method first arg | `self` |
| Class method first arg | `cls` |
| Public attribute | no leading underscore by default |
| Non-public attribute | single leading underscore when explicitly supported |
| Dunder name | only when explicitly supported |
| Built-in constants | `True`, `False`, `None` |
| Keyword collision | trailing underscore only when explicitly supported |

## Prompt Strategy

Code mode should have its own endpoint-specific prompt rather than trying to
overload `default` or `dictation`.

Recommended prompt themes:

- "conservative Python code correction editor"
- "optimize for exact tokens and Python naming conventions"
- "comments/docstrings may remain prose"
- "never invent code"
- "when syntax is ambiguous, keep the raw wording"

Prompt examples should explicitly cover:

- `snake_case` function names
- `CapWords` class names
- `UPPER_SNAKE_CASE` constants
- `self` / `cls`
- `True` / `False` / `None`
- `__init__`
- mixed prose + code
- comments
- docstrings
- ambiguity fallback

Prompt focus should stay narrower than prose correction because the endpoint is
English-only and Python-only at launch.

The prompt should also assume a smarter reasoning budget than the prose path if
the serving model is Sonnet-tier.

## Streaming Prompt Template

Recommended but optional in the same project:

- add a server-minted streaming prompt template for Python editor use,
  distinct from the `/correct` prompt

Suggested template intent:

- bias ASR slightly toward code tokens and symbol words
- bias toward implicit Python header interpretation for common patterns
- do not trade away turn detection for aggressive formatting
- keep keyterms as the primary mechanism for project-specific identifiers

This is helpful, but the core of the feature is the `/correct_code` behavior.

## Safety and Fallbacks

Existing safety posture should carry over:

- malformed model output falls back to raw
- suspect rewrites fall back to raw
- self-correction resolution in single-turn mode falls back to raw

Code mode should not use protected-term preservation as a blocking validation
rule. Protected terms remain useful as generation hints, especially for project
symbols, but the validator should not reject output solely because a protected
term was not reproduced verbatim.

Code-mode-specific safety additions:

- if the model introduces unsupported code structure not present in the raw
  utterance, fall back to raw
- if the model expands an unknown identifier into a library-specific symbol
  without evidence, fall back to raw
- if the model turns prose into code without strong support, fall back to raw
- if deterministic validation fails after one repair attempt, fall back to raw

## English-only restriction

Launch Code mode should be explicitly English-only.

Product rule:

- Code mode is available only when the session uses the standard English
  transcriber.

API rule:

- `/correct_code` accepts only English-mode requests.

Why this is worth the restriction:

- Python symbol dictation is already hard enough in English
- multilingual transliteration would add noise without clear user value in v1
- the prompt can stay tightly focused on Python token repair rather than
  language detection or transliteration behavior
- validation rules stay simpler and more trustworthy

## Eval Spec

The current `structured_entry` eval coverage should be retired and replaced by a
Python Code mode suite for the dedicated `/correct_code` endpoint.

Separately, the former structured-entry positive and safety cases should be
folded into the standard `/correct` eval suite, since those behaviors now
belong to `Standard`.

### Core eval categories

- no-change stability on already-correct Python
- `snake_case` normalization for functions and variables
- `CapWords` normalization for classes
- `UPPER_SNAKE_CASE` normalization for constants
- `self` / `cls` handling
- Python keyword preservation
- `True` / `False` / `None` casing
- underscore and dunder handling
- punctuation and symbol restoration
- implicit punctuation inference for common Python constructs
- comment preservation
- docstring handling
- mixed code + prose utterances
- protected project identifier preservation
- ambiguity preservation
- no hallucinated imports / decorators / types / literals
- self-correction non-resolution in code context
- validation-pass / validation-fail / raw-fallback behavior
- English-only rejection behavior for unsupported requests

### Adversarial ASR-style cases

The suite should aggressively target realistic ASR failure modes:

- split identifiers:
  - `user id` / `request handler` / `base url`
- casing confusion:
  - `none` / `true` / `false`
- homophones:
  - `for` vs `four`
  - `to` vs `two`
  - `in` vs `inn`
  - `class` vs `glass`
- punctuation words:
  - `colon`, `comma`, `dot`, `underscore`, `double underscore`
- implicit punctuation cases:
  - `def get user by id self user id`
  - `class user profile base model`
  - `if user is none`
- indentation words:
  - `tab`, `indent`, `dedent`, `four spaces`
- ambiguous camel/snake/class names:
  - `user profile`
  - `api client`
  - `http error`
- keyword collisions:
  - `class`, `type`, `match`
- over-specific library guessing:
  - `requests session` should not become `requests.Session` unless supported
- partial code fragments:
  - `from fast api import`
  - `def get user`
- mixed prose/editor commands:
  - `comment this caches the result`
  - `triple quote return the active user triple quote`

### Example gold cases

Positive:

- `def get user by id self user id`
  -> `def get_user_by_id(self, user_id):`

- `class user profile base model`
  -> `class UserProfile(BaseModel):`

- `cache key equals none`
  -> `cache_key = None`

- `dunder init self`
  -> `__init__(self):`

Negative / safety:

- `requests session`
  should not become `requests.Session`

- `open the fast api file`
  should not become `FastAPIFile`

- `from fast api import`
  should not invent the imported symbol

Validation-specific:

- output with consistent tab indentation should be accepted
- output with mixed tab/space indentation in the same block should fail
- invalid Python header punctuation should fail validation
- multilingual request to `/correct_code` should be rejected

## Rollout Plan

### Implementation order

The rollout splits into two PRs so the second is purely additive:

- **PR 1 — `structured_entry` retirement (this session).** Folds former
  Structured behavior into `default`, removes `Structured` from the iOS mode
  picker, auto-migrates persisted `structured` preferences to `standard`, and
  keeps `structured_entry` as a deprecated server-side alias of `default` for
  one compatibility window.
- **PR 2 — Code mode introduction (next).** Adds the `Code` mode to the iOS
  picker (Python-only, English Standard transcriber only), introduces
  `POST /correct_code` with its dedicated prompt and deterministic validation
  pass, and wires the Sonnet-tier generator with raw fallback.

### Product rollout (full checklist)

1. Ship Code mode behind the existing settings surface.
2. Fold former Structured behavior into Standard mode.
3. Remove Structured from the visible mode picker.
4. Migrate persisted `structured` preference to `standard`.
5. Add `POST /correct_code` with validation and raw fallback.
6. Keep Python as the only code language in v1.
7. Restrict Code mode to English Standard transcriber.
8. Launch the endpoint with a Sonnet-tier model unless latency/cost testing
   clearly disqualifies it.

Steps 2–4 ship in PR 1. Steps 1 and 5–8 ship in PR 2.

### Documentation updates

When implementation starts, update:

- `README.md`
- `correction-spec.md`
- `CLAUDE.md`
- `server/CLAUDE.md`
- adversarial eval docs and cases

## Risks

- **Over-formatting risk**:
  code mode may aggressively force identifiers into `snake_case` even when the
  user intended prose. Mitigation: require clear code context.

- **Library-guessing risk**:
  models may expand identifiers into familiar framework symbols. Mitigation:
  explicit prompt prohibitions and adversarial evals.

- **UI complexity creep**:
  language pickers can sprawl before they are useful. Mitigation: Python only in
  v1, no real picker until a second language ships.

- **Backward-compatibility risk**:
  removing `structured_entry` may surprise old clients. Mitigation: explicit
  migration plan and temporary aliasing to `default`, not to `code`.

- **Prompt overlap risk**:
  dictation-like punctuation commands and code symbol commands may conflict.
  Mitigation: separate Code-mode endpoint, separate prompt, and dedicated eval
  coverage.

- **Validation false-negative risk**:
  valid code fragments may be rejected by an overly strict validator.
  Mitigation: snippet-kind classification and fragment-aware validation rather
  than unconditional full parsing.

- **Validation false-positive risk**:
  lightweight validation may approve code that is still wrong.
  Mitigation: treat validation as a safety filter, not a proof of correctness,
  and keep strong adversarial eval coverage.

- **Latency/cost risk**:
  a Sonnet-tier model is more expensive and likely slower than Haiku.
  Mitigation: isolate Code mode on its own endpoint, measure actual usage, and
  retain the option to move to Haiku-first with Sonnet escalation later.

## Open Questions

These do not block the spec, but they should be decided before implementation:

1. Should validation expose detailed reason codes to the client, or stay
   server-observability-only in v1?
2. Should Code mode launch directly on a Sonnet-tier model, or do we want to
   benchmark Haiku-first vs Sonnet-first before deciding?
3. How aggressive should implicit punctuation inference be before the system
   falls back to requiring spoken symbol words for disambiguation?
4. Should comments/docstrings use the same correction pass, or should Code mode
   treat them as a lighter prose sub-mode within the same prompt?

### Resolved

- **Persisted `structured` preference migration.** Auto-migrate to `standard`
  on first launch after the retirement PR. An unknown persisted `mode` raw
  value falls through to `.standard` and re-persists, so old installs never see
  a broken picker state.

## Recommendation

Proceed with:

- replacing `structured` with `code`
- folding structured-entry conveniences into `Standard`
- Python as the only launch language
- no actual language picker yet
- a dedicated `/correct_code` endpoint with `code_language: "python"`
- a deterministic validation pass with one optional repair attempt
- a Sonnet-tier primary model for `/correct_code`, not pure Haiku
- standard-transcriber-only support at launch
- a fresh adversarial eval suite built around Python ASR failure modes

This gives VoxScribe a mode that matches real editor use while staying aligned
with the existing product principle: conservative correction first, cleverness
only when the text truly supports it.

## Sources

- [PEP 8 – Style Guide for Python Code](https://peps.python.org/pep-0008/)
- [Python Language Reference: Lexical analysis](https://docs.python.org/3/reference/lexical_analysis.html)
- [PEP 257 – Docstring Conventions](https://peps.python.org/pep-0257/)
