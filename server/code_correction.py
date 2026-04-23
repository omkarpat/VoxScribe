"""Single-turn Python code correction for /correct_code.

Sonnet-tier primary generator plus deterministic validation. Falls back to raw
text on API error, malformed model output, or validation failure.
"""

from __future__ import annotations

import json
import logging
import os

from anthropic import AsyncAnthropic

from code_validation import validate

logger = logging.getLogger(__name__)

SONNET_MODEL = "claude-sonnet-4-6"
MAX_OUTPUT_TOKENS = 512

# ---------------------------------------------------------------------------
# Python-focused system prompt
# ---------------------------------------------------------------------------

_PYTHON_PROMPT = """You are a conservative single-turn ASR cleanup editor for a live voice keyboard used inside a Python editor.

Your job is to turn one spoken turn into correctly formatted Python source, comments, or a docstring. You are NOT a code generator. You do not invent structure the user did not speak.

Input:
- RAW: one finalized ASR turn, possibly containing Python code, a comment, or a docstring.
- PROTECTED: JSON terms to preserve exactly (project identifiers, class names, libraries).

Conventions (apply only when the raw utterance clearly supports them):
- functions / local variables / parameters / methods: snake_case
- classes: CapWords
- module-level constants: UPPER_SNAKE_CASE
- instance method first parameter: self
- class method first parameter: cls
- Python keywords stay lowercase: def, class, if, else, for, while, with, try, except, return, import, from, as, in, is, not, and, or, pass, lambda, yield
- Python built-ins keep exact casing: True, False, None

Implicit punctuation:
- infer () and : for obvious def / class / if / for / while / with headers
- infer commas between parameters when the pattern is structurally clear
- infer _ inside identifiers when code context strongly supports an identifier

Canonical token repair is allowed when meaning is preserved:
- `user id` -> `user_id` when clearly an identifier
- `dunder init` -> `__init__`
- `none`/`true`/`false` -> `None`/`True`/`False` in code context
- `open ai api key` -> `OPENAI_API_KEY` when clearly dictated as an env var or code identifier
- `version two point one` -> `version 2.1` in package/config/code context

Comments and docstrings:
- lines that start with the word `comment` become `# ...` readable prose
- `triple quote ... triple quote` becomes a triple-double-quoted docstring
- comments and docstrings may stay as natural prose; do not force code syntax on them

Do NOT:
- invent imports, module paths, decorators, class hierarchies, default values, type hints, or literals the user did not speak
- change one valid identifier into a more famous one (no `requests.Session` from `requests session`, no `FastAPIFile` from `fast api file`)
- complete partial fragments from general programming knowledge
- resolve self-corrections (`no actually`, `I mean`, `scratch that` — keep both sides)
- reflow multi-line structure based on guesswork
- turn plainly prose utterances into code

When ambiguous, keep the raw wording. Under-correction is better than unsupported specificity.

Output a single Python snippet via the submit tool. Do not wrap in code fences.
"""

_PYTHON_EXAMPLES = """Examples:

PROTECTED: []
RAW: def get user by id self user id
OUTPUT (cleaned_text): def get_user_by_id(self, user_id):

PROTECTED: ["BaseModel"]
RAW: class user profile base model
OUTPUT (cleaned_text): class UserProfile(BaseModel):

PROTECTED: []
RAW: cache key equals none
OUTPUT (cleaned_text): cache_key = None

PROTECTED: []
RAW: if user is none
OUTPUT (cleaned_text): if user is None:

PROTECTED: []
RAW: dunder init self
OUTPUT (cleaned_text): __init__(self):

PROTECTED: []
RAW: set env var open ai api key
OUTPUT (cleaned_text): OPENAI_API_KEY

PROTECTED: []
RAW: install pydantic version two point one
OUTPUT (cleaned_text): install pydantic version 2.1

PROTECTED: []
RAW: comment this caches the result
OUTPUT (cleaned_text): # this caches the result

PROTECTED: []
RAW: triple quote return the active user triple quote
OUTPUT (cleaned_text): \"\"\"Return the active user.\"\"\"

PROTECTED: []
RAW: requests session
OUTPUT (cleaned_text): requests session

PROTECTED: []
RAW: from fast api import
OUTPUT (cleaned_text): from fast api import

PROTECTED: []
RAW: open the fast api file
OUTPUT (cleaned_text): open the fast api file
"""

_SYSTEM_PROMPT = f"{_PYTHON_PROMPT}\n{_PYTHON_EXAMPLES}"

# ---------------------------------------------------------------------------
# Forced tool definition
# ---------------------------------------------------------------------------

_CORRECTION_TOOL = {
    "name": "submit_single_turn_code_correction",
    "description": "Return the cleaned Python snippet for a single ASR turn.",
    "input_schema": {
        "type": "object",
        "properties": {
            "cleaned_text": {
                "type": "string",
                "description": "The corrected Python snippet, comment, or docstring.",
            },
        },
        "required": ["cleaned_text"],
    },
}

# ---------------------------------------------------------------------------
# Client singleton
# ---------------------------------------------------------------------------

_client: AsyncAnthropic | None = None


def _get_client() -> AsyncAnthropic:
    global _client
    if _client is None:
        _client = AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    return _client


def _format_user_message(raw: str, protected_terms: list[str]) -> str:
    pt = json.dumps(protected_terms, ensure_ascii=False)
    return f"PROTECTED: {pt}\nRAW: {raw}"


async def _generate(raw: str, protected_terms: list[str]) -> str | None:
    try:
        resp = await _get_client().messages.create(
            model=SONNET_MODEL,
            max_tokens=MAX_OUTPUT_TOKENS,
            system=[
                {
                    "type": "text",
                    "text": _SYSTEM_PROMPT,
                    "cache_control": {"type": "ephemeral"},
                }
            ],
            tools=[_CORRECTION_TOOL],
            tool_choice={
                "type": "tool",
                "name": "submit_single_turn_code_correction",
                "disable_parallel_tool_use": True,
            },
            messages=[{"role": "user", "content": _format_user_message(raw, protected_terms)}],
        )
    except Exception:
        logger.exception("sonnet call failed; falling back to raw")
        return None

    usage = getattr(resp, "usage", None)
    if usage:
        logger.info(
            "sonnet usage (code) input=%d output=%d cache_read=%d cache_write=%d",
            getattr(usage, "input_tokens", 0),
            getattr(usage, "output_tokens", 0),
            getattr(usage, "cache_read_input_tokens", 0),
            getattr(usage, "cache_creation_input_tokens", 0),
        )

    for block in resp.content:
        if getattr(block, "type", None) == "tool_use" and getattr(block, "name", None) == "submit_single_turn_code_correction":
            cleaned = block.input.get("cleaned_text")
            if isinstance(cleaned, str):
                return cleaned

    logger.warning("no tool_use block in sonnet response; falling back to raw")
    return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def correct_code_turn(raw: str, protected_terms: list[str]) -> str:
    """Return a cleaned Python snippet. Falls back to raw on any failure."""
    if not raw.strip():
        return raw

    cleaned = await _generate(raw, protected_terms)
    if cleaned is None:
        return raw

    cleaned = cleaned.rstrip("\n")
    if not cleaned.strip():
        return raw

    result = validate(cleaned)
    logger.info(
        "code_validation status=%s kind=%s reason=%s",
        result.status,
        result.kind,
        result.reason or "-",
    )
    if result.status != "passed":
        return raw

    return cleaned
