import json
import logging
import os

from anthropic import AsyncAnthropic

from schemas import CorrectionProfile

logger = logging.getLogger(__name__)

HAIKU_MODEL = "claude-haiku-4-5"
MAX_OUTPUT_TOKENS = 512

LENGTH_DRIFT_MIN_RATIO = 0.5
LENGTH_DRIFT_MAX_RATIO = 2.0

# ---------------------------------------------------------------------------
# Per-profile system prompts
# ---------------------------------------------------------------------------

_SHARED_PROMPT = """You are a conservative ASR correction editor for a live voice keyboard and general-purpose voice text-input system.

The corrected text may be inserted into notes, chat, email, search, forms, or structured fields.

Input:
- one raw ASR transcript turn
- a JSON list of PROTECTED terms

Your job:
- Restore punctuation and sentence boundaries when clearly supported.
- Truecase sentence starts and clear proper nouns.
- Remove obvious filler words (um, uh, mid-thought "like", "you know") only when they are clearly non-meaningful.
- Clean harmless immediate repetitions or false starts only when meaning does not change.
- Preserve every PROTECTED term exactly — same spelling, same casing — wherever it appears.

Hard rules:
- Do NOT summarize.
- Do NOT paraphrase for style.
- Do NOT make the text more formal, more concise, or more note-like than the raw speech supports.
- Do NOT substitute synonyms unless clearly required to fix an ASR error.
- Do NOT translate any text, including code-switched or non-English words.
- Do NOT add content, names, numbers, dates, or entities not already supported by the raw text.
- Do NOT resolve self-corrections. Phrases like "no actually X", "no wait X", "I mean X", "scratch that X", and "no make that X" are self-correction markers. Keep both the original value and the corrected value in the output verbatim. Resolving self-corrections is Phase 3 behavior.
- Do NOT convert spoken number words to digits when they appear inside a self-correction.
- Do NOT change meaning, even slightly.
- If the raw text is already clean, return it unchanged.
- When multiple outputs are plausible, keep the raw wording.
"""

_DEFAULT_PROFILE = """Profile: default
Apply standard transcript cleanup only.

Examples:

PROTECTED: ["VoxScribe", "AssemblyAI", "Haiku"]
RAW: so um were building a voxscribe demo with assemblyai and claude haiku
OUTPUT (cleaned_text): So we're building a VoxScribe demo with AssemblyAI and Claude Haiku.

PROTECTED: []
RAW: lets meet at 2 no actually 3
OUTPUT (cleaned_text): Let's meet at 2, no actually 3.

PROTECTED: ["yaar", "chai"]
RAW: arre yaar chalo chai pi lete hain
OUTPUT (cleaned_text): Arre yaar, chalo chai pi lete hain.

PROTECTED: ["FastAPI"]
RAW: i wa i want to finish the fastapi endpoint today
OUTPUT (cleaned_text): I want to finish the FastAPI endpoint today."""

_DICTATION_PROFILE = """Profile: dictation
Interpret spoken punctuation and formatting commands as punctuation only when they are clearly being used as commands rather than literal words.

Command mapping:
- "period" or "full stop" → "."
- "comma" → ","
- "question mark" → "?"
- "exclamation mark" or "exclamation" → "!"
- "colon" → ":"
- "semicolon" → ";"
- "new paragraph" or "new paragraphs" → "\\n\\n"
- "new line" → "\\n"
- "open quote" or "open quotes" → '"'
- "close quote" or "close quotes" → '"'

If a word like "period" appears as part of natural prose, keep its literal meaning.

Examples:

PROTECTED: []
RAW: remind me to buy milk period new paragraph call the dentist question mark
OUTPUT (cleaned_text): Remind me to buy milk.

Call the dentist?

PROTECTED: []
RAW: during that period I was traveling
OUTPUT (cleaned_text): During that period I was traveling."""

_STRUCTURED_ENTRY_PROFILE = """Profile: structured_entry
Normalize structured data only when the raw text strongly supports a specific normalization.

Allowed when strongly supported:
- email addresses
- phone numbers
- URLs
- version numbers
- numeric IDs

Do NOT invent digits, domain names, TLDs, or version components.
Do NOT normalize if the input is partial or ambiguous.
When unsure, preserve the raw wording.

Examples:

PROTECTED: []
RAW: my email is john dot doe at gmail dot com
OUTPUT (cleaned_text): My email is john.doe@gmail.com.

PROTECTED: []
RAW: maybe call me at five five
OUTPUT (cleaned_text): Maybe call me at five five."""

_PROMPTS: dict[str, str] = {
    "default": f"{_SHARED_PROMPT}\n\n{_DEFAULT_PROFILE}",
    "dictation": f"{_SHARED_PROMPT}\n\n{_DEFAULT_PROFILE}\n\n{_DICTATION_PROFILE}",
    "structured_entry": f"{_SHARED_PROMPT}\n\n{_DEFAULT_PROFILE}\n\n{_STRUCTURED_ENTRY_PROFILE}",
}

# ---------------------------------------------------------------------------
# Forced tool definition
# ---------------------------------------------------------------------------

_CORRECTION_TOOL = {
    "name": "submit_single_turn_correction",
    "description": "Return the cleaned transcript for a single ASR turn.",
    "input_schema": {
        "type": "object",
        "properties": {
            "cleaned_text": {
                "type": "string",
                "description": "The corrected transcript text.",
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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _format_user_message(raw: str, protected_terms: list[str]) -> str:
    pt = json.dumps(protected_terms, ensure_ascii=False)
    return f"PROTECTED: {pt}\nRAW: {raw}"


def _is_low_entropy(raw: str) -> bool:
    """Detect garbage input where most 'words' are single-character runs.

    Examples that should return True: "aaaaa bbbbb ccccc", "xxxx yyyy zzzz".
    These are low-signal inputs that invite the model to hallucinate structure.
    """
    words = raw.split()
    significant = [w for w in words if len(w) >= 3 and w.isalpha()]
    if len(significant) < 2:
        return False
    suspect = sum(1 for w in significant if len(set(w.lower())) == 1)
    return suspect / len(significant) >= 0.5


def _passes_safety(raw: str, cleaned: str, protected_terms: list[str]) -> tuple[bool, str]:
    """Return (ok, reason_code). reason_code is non-empty on failure."""
    if not cleaned:
        return False, "empty_output"

    raw_len = len(raw)
    if raw_len > 0:
        ratio = len(cleaned) / raw_len
        if ratio < LENGTH_DRIFT_MIN_RATIO or ratio > LENGTH_DRIFT_MAX_RATIO:
            return False, f"length_drift(ratio={ratio:.2f})"

    raw_lower = raw.lower()
    for term in protected_terms:
        if term.lower() in raw_lower and term not in cleaned:
            return False, f"protected_term_dropped({term!r})"

    return True, ""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def correct_single_turn(
    raw: str,
    protected_terms: list[str],
    profile: CorrectionProfile = "default",
) -> str:
    """Return a cleaned transcript. Falls back to raw on any safety or API failure."""
    if not raw.strip():
        return raw

    if _is_low_entropy(raw):
        logger.info("low-entropy input detected; skipping Haiku and returning raw profile=%s", profile)
        return raw

    system_prompt = _PROMPTS[profile]

    try:
        resp = await _get_client().messages.create(
            model=HAIKU_MODEL,
            max_tokens=MAX_OUTPUT_TOKENS,
            system=[
                {
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"},
                }
            ],
            tools=[_CORRECTION_TOOL],
            tool_choice={
                "type": "tool",
                "name": "submit_single_turn_correction",
                "disable_parallel_tool_use": True,
            },
            messages=[{"role": "user", "content": _format_user_message(raw, protected_terms)}],
        )
    except Exception:
        logger.exception("Haiku call failed; falling back to raw profile=%s", profile)
        return raw

    # Log cache telemetry
    usage = getattr(resp, "usage", None)
    if usage:
        logger.info(
            "haiku usage profile=%s input=%d output=%d cache_read=%d cache_write=%d",
            profile,
            getattr(usage, "input_tokens", 0),
            getattr(usage, "output_tokens", 0),
            getattr(usage, "cache_read_input_tokens", 0),
            getattr(usage, "cache_creation_input_tokens", 0),
        )

    # Extract the tool_use block
    cleaned: str | None = None
    for block in resp.content:
        if getattr(block, "type", None) == "tool_use" and getattr(block, "name", None) == "submit_single_turn_correction":
            cleaned = block.input.get("cleaned_text")
            break

    if cleaned is None:
        logger.warning("no tool_use block in Haiku response; falling back to raw profile=%s", profile)
        return raw

    cleaned = cleaned.strip()
    ok, reason = _passes_safety(raw, cleaned, protected_terms)
    if not ok:
        logger.warning("safety guard tripped reason=%s profile=%s; falling back to raw", reason, profile)
        return raw

    return cleaned
