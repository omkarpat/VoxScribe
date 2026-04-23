import json
import logging
import os

from anthropic import AsyncAnthropic

from schemas import CorrectionProfile, Transcriber

logger = logging.getLogger(__name__)

HAIKU_MODEL = "claude-haiku-4-5"
MAX_OUTPUT_TOKENS = 512

LENGTH_DRIFT_MIN_RATIO = 0.5
LENGTH_DRIFT_MAX_RATIO = 2.0

# ---------------------------------------------------------------------------
# Per-profile system prompts
# ---------------------------------------------------------------------------

_STANDARD_SHARED = """You are a conservative single-turn ASR cleanup editor for a live voice keyboard.

AssemblyAI already formats RAW with casing and punctuation. Treat RAW as the baseline; make only local fixes that are clearly supported.

Input:
- RAW: one finalized ASR turn.
- PROTECTED: JSON terms to preserve exactly.

Do:
- Lightly fix missing or wrong punctuation/casing when obvious (sentence starts, clear questions, simple sentence breaks).
- Remove obvious filler/disfluency and harmless immediate repetitions or false starts.
- Return empty only when the whole turn has no substantive content. Short replies like "yeah", "no", and "okay" are content.
- Preserve PROTECTED terms exactly.
- Normalize complete email, phone, URL, and numeric ID tokens only when all required parts are present.
- Repair obvious lexical tokens without adding detail, e.g. "read me" -> "README", "api" -> "API".

Do not:
- Rewrite style, summarize, translate, or change meaning.
- Guess missing details or make vague text more specific.
- Complete partial email, phone, URL, or version fragments by adding missing pieces.
- Turn spoken version numbers into numeric shorthand; keep "version two" as words.
- Resolve or canonicalize self-corrections; keep both sides and their spoken value forms for "no actually", "no wait", "I mean", or "scratch that".
- If unsure, keep RAW.
"""

_MULTILINGUAL_SHARED = """You are a conservative single-turn ASR cleanup editor for a live voice keyboard.

AssemblyAI already formats RAW with casing and punctuation. Treat RAW as the baseline; make only local fixes that are clearly supported. Output must be Latin script.

Input:
- RAW: one finalized ASR turn.
- DETECTED_LANGUAGE: ASR language code.

Do:
- Lightly fix missing or wrong punctuation/casing when obvious.
- Remove obvious filler/disfluency and harmless immediate repetitions or false starts.
- Return empty only when the whole turn has no substantive content. Short replies like "yeah", "no", and "okay" are content.
- Return empty for whole-turn Whisper-RT boilerplate hallucinations such as "Thanks for watching", "Please subscribe", subtitle credits, or close variants. Keep those words if they are part of real speech.
- Transliterate non-Latin script to Latin for DETECTED_LANGUAGE. Do not translate.
- Normalize complete email, phone, URL, and numeric ID tokens only when all required parts are present.

Do not:
- Rewrite style, summarize, translate, or change meaning.
- Guess missing details or make vague text more specific.
- Complete partial email, phone, URL, or version fragments by adding missing pieces.
- Turn spoken version numbers into numeric shorthand; keep "version two" as words.
- Resolve or canonicalize self-corrections; keep both sides and their spoken value forms for "no actually", "no wait", "I mean", or "scratch that".
- If unsure, keep RAW.
"""

_STANDARD_DEFAULT_EXAMPLES = """Profile: default
Examples:

PROTECTED: ["VoxScribe", "AssemblyAI", "Haiku"]
RAW: So, um, we're building a Voxscribe demo with Assemblyai and Claude Haiku.
OUTPUT (cleaned_text): So we're building a VoxScribe demo with AssemblyAI and Claude Haiku.

PROTECTED: []
RAW: what time is the meeting tomorrow
OUTPUT (cleaned_text): What time is the meeting tomorrow?

PROTECTED: []
RAW: Let's meet at 2, no actually 3.
OUTPUT (cleaned_text): Let's meet at 2, no actually 3.

PROTECTED: []
RAW: my email is john dot doe at gmail dot com
OUTPUT (cleaned_text): My email is john.doe@gmail.com.

PROTECTED: []
RAW: call me at six five zero five five five
OUTPUT (cleaned_text): Call me at six five zero five five five.

PROTECTED: []
RAW: go to docs dot example
OUTPUT (cleaned_text): Go to docs dot example.

PROTECTED: []
RAW: install version two point
OUTPUT (cleaned_text): Install version two point.

PROTECTED: []
RAW: Hm, um.
OUTPUT (cleaned_text):

PROTECTED: []
RAW: Uh, yeah.
OUTPUT (cleaned_text): Yeah."""

_MULTILINGUAL_DEFAULT_EXAMPLES = """Profile: default
Examples:

DETECTED_LANGUAGE: hi
RAW: यार चाय पी लेते हैं
OUTPUT (cleaned_text): Yaar, chai pi lete hain.

DETECTED_LANGUAGE: hi
RAW: मुझे कल मुंबई जाना है
OUTPUT (cleaned_text): Mujhe kal Mumbai jaana hai.

DETECTED_LANGUAGE: en
RAW: Thanks for watching.
OUTPUT (cleaned_text):

DETECTED_LANGUAGE: en
RAW: Alright, thanks for watching the demo, let me know what you think.
OUTPUT (cleaned_text): Alright, thanks for watching the demo, let me know what you think.

DETECTED_LANGUAGE: en
RAW: Uh, yeah.
OUTPUT (cleaned_text): Yeah."""

_DICTATION_PROFILE = """Profile: dictation
Interpret spoken punctuation/formatting commands only when clearly used as commands. If the phrase is ordinary prose, keep it literal.

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

Examples:

RAW: Remind me to buy milk period new paragraph call the dentist question mark.
OUTPUT (cleaned_text): Remind me to buy milk.

Call the dentist?

RAW: During that period I was traveling.
OUTPUT (cleaned_text): During that period I was traveling.

RAW: Open quote is what the button is called.
OUTPUT (cleaned_text): Open quote is what the button is called."""

_PROMPTS: dict[tuple[Transcriber, CorrectionProfile], str] = {
    ("standard", "default"): f"{_STANDARD_SHARED}\n\n{_STANDARD_DEFAULT_EXAMPLES}",
    ("standard", "dictation"): f"{_STANDARD_SHARED}\n\n{_STANDARD_DEFAULT_EXAMPLES}\n\n{_DICTATION_PROFILE}",
    ("multilingual", "default"): f"{_MULTILINGUAL_SHARED}\n\n{_MULTILINGUAL_DEFAULT_EXAMPLES}",
    ("multilingual", "dictation"): f"{_MULTILINGUAL_SHARED}\n\n{_MULTILINGUAL_DEFAULT_EXAMPLES}\n\n{_DICTATION_PROFILE}",
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

def _format_user_message(
    raw: str,
    protected_terms: list[str],
    detected_language: str | None,
    transcriber: Transcriber,
) -> str:
    if transcriber == "multilingual":
        lang = detected_language or "unknown"
        return f"DETECTED_LANGUAGE: {lang}\nRAW: {raw}"
    pt = json.dumps(protected_terms, ensure_ascii=False)
    return f"PROTECTED: {pt}\nRAW: {raw}"


def _passes_safety(
    raw: str,
    cleaned: str,
    protected_terms: list[str],
    transcriber: Transcriber,
) -> tuple[bool, str]:
    """Return (ok, reason_code). reason_code is non-empty on failure.

    Empty cleaned output is a valid result (pure-disfluency turn), so all
    length and protected-term checks short-circuit and pass.
    """
    if not cleaned:
        return True, ""

    # Transliteration (e.g. Devanagari → Latin) can 2–3× the character count,
    # so the length-drift guard is wider in multilingual mode.
    max_ratio = 3.5 if transcriber == "multilingual" else LENGTH_DRIFT_MAX_RATIO

    raw_len = len(raw)
    if raw_len > 0:
        ratio = len(cleaned) / raw_len
        if ratio < LENGTH_DRIFT_MIN_RATIO or ratio > max_ratio:
            return False, f"length_drift(ratio={ratio:.2f})"

    if transcriber == "standard":
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
    detected_language: str | None = None,
    transcriber: Transcriber = "standard",
) -> str:
    """Return a cleaned transcript. Falls back to raw on any safety or API failure."""
    if not raw.strip():
        return raw

    system_prompt = _PROMPTS[(transcriber, profile)]

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
            messages=[{"role": "user", "content": _format_user_message(raw, protected_terms, detected_language, transcriber)}],
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
    ok, reason = _passes_safety(raw, cleaned, protected_terms, transcriber)
    if not ok:
        logger.warning("safety guard tripped reason=%s profile=%s; falling back to raw", reason, profile)
        return raw

    return cleaned
