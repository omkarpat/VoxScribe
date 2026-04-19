import json
import logging
import os

from anthropic import AsyncAnthropic

logger = logging.getLogger(__name__)

HAIKU_MODEL = "claude-haiku-4-5"
MAX_OUTPUT_TOKENS = 512

LENGTH_DRIFT_MIN_RATIO = 0.5
LENGTH_DRIFT_MAX_RATIO = 2.0

SYSTEM_PROMPT = """You are a transcription cleanup assistant for a live dictation app.

Input: a single-turn raw transcript from an automatic speech recognizer, plus a list of PROTECTED terms that must be preserved exactly.

Your job:
- Add punctuation and fix casing (sentence starts, proper nouns).
- Remove obvious disfluencies only when clearly not meaningful: "um", "uh", mid-thought "like", "you know".
- Preserve every PROTECTED term exactly — same spelling, same casing — wherever the speaker said it.
- Preserve self-corrections verbatim. If the speaker says "two no actually three", keep that wording (add punctuation but do not resolve to "three"). Resolving self-corrections is not your job.
- Do not add content. Do not summarize. Do not rewrite meaning.
- Do not translate non-English words to English. Keep Hinglish, code-switching, and proper nouns in the speaker's language.

Output: the cleaned transcript text and nothing else. No prefix, no quotes, no explanation.

Examples:

RAW: so um were building a voxscribe demo with assemblyai and claude haiku
PROTECTED: ["VoxScribe", "AssemblyAI", "Claude", "Haiku"]
OUTPUT: So we're building a VoxScribe demo with AssemblyAI and Claude Haiku.

RAW: lets meet at 2 no actually 3
PROTECTED: []
OUTPUT: Let's meet at 2, no actually 3.

RAW: arre yaar chalo chai pi lete hain
PROTECTED: ["yaar", "chalo", "chai"]
OUTPUT: Arre yaar, chalo chai pi lete hain.

RAW: i think the fastapi server is at like port 8000 or something
PROTECTED: ["FastAPI"]
OUTPUT: I think the FastAPI server is at port 8000."""


_client: AsyncAnthropic | None = None


def _get_client() -> AsyncAnthropic:
    global _client
    if _client is None:
        _client = AsyncAnthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    return _client


def _format_user_message(raw: str, protected_terms: list[str]) -> str:
    pt = json.dumps(protected_terms, ensure_ascii=False)
    return f"PROTECTED: {pt}\nRAW: {raw}\nOUTPUT:"


def _passes_safety(raw: str, cleaned: str, protected_terms: list[str]) -> bool:
    raw_len = len(raw)
    if raw_len > 0:
        ratio = len(cleaned) / raw_len
        if ratio < LENGTH_DRIFT_MIN_RATIO or ratio > LENGTH_DRIFT_MAX_RATIO:
            logger.warning("correction length drift: raw=%d cleaned=%d ratio=%.2f", raw_len, len(cleaned), ratio)
            return False

    raw_lower = raw.lower()
    for term in protected_terms:
        if term.lower() in raw_lower and term not in cleaned:
            logger.warning("correction dropped protected term: %r", term)
            return False
    return True


async def correct_single_turn(raw: str, protected_terms: list[str]) -> str:
    """Return a cleaned transcript. Falls back to raw on any safety or API failure."""
    if not raw.strip():
        return raw

    try:
        resp = await _get_client().messages.create(
            model=HAIKU_MODEL,
            max_tokens=MAX_OUTPUT_TOKENS,
            system=[
                {
                    "type": "text",
                    "text": SYSTEM_PROMPT,
                    "cache_control": {"type": "ephemeral"},
                }
            ],
            messages=[{"role": "user", "content": _format_user_message(raw, protected_terms)}],
        )
    except Exception:
        logger.exception("Haiku call failed; falling back to raw")
        return raw

    try:
        cleaned = resp.content[0].text.strip()
    except (AttributeError, IndexError):
        logger.warning("Haiku response missing text content; falling back to raw")
        return raw

    if not cleaned:
        return raw
    if not _passes_safety(raw, cleaned, protected_terms):
        return raw
    return cleaned
