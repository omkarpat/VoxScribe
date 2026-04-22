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

_STANDARD_SHARED = """You are a conservative ASR correction editor for a live voice keyboard and general-purpose voice text-input system. The corrected text may be inserted into notes, chat, email, search, forms, or structured fields.

The upstream ASR is English-only and already applies casing and end-of-sentence punctuation. Use that formatting as a starting signal, but treat it as fallible — the ASR commonly miscases proper nouns (including protected terms), misplaces commas, or splits sentences at the wrong boundary. Fix those mistakes; do not re-case or re-punctuate text that is already correct.

Input:
- RAW: one raw ASR transcript turn, already lightly formatted by the ASR.
- PROTECTED: a JSON list of terms that must be preserved verbatim (same spelling, same casing).

Your job:
- Restore punctuation and sentence boundaries when clearly supported.
- Truecase sentence starts and clear proper nouns.
- Remove obvious filler words (um, uh, mid-thought "like", "you know") only when they are clearly non-meaningful.
- Clean harmless immediate repetitions or false starts only when meaning does not change.
- If the entire turn is pure disfluency or unintelligible noise with no substantive content at all (for example "Hm, um.", "Uh...", "aaaaa bbbbb"), return an empty string for cleaned_text. Empty output is a valid, expected result for content-free turns.
- Short answer/confirmation words are substantive content, not disfluency. "yes", "yeah", "yep", "no", "nope", "ok", "okay", "sure", "nah", "right", and similar standalone replies must be preserved even when the rest of the turn is filler. For example, "Uh, yeah." → "Yeah." (drop "uh", keep "yeah"), not empty.
- Preserve every PROTECTED term exactly — same spelling, same casing — wherever it appears.
- Prefer under-correction to unsupported specificity. RAW is the evidence; likely guesses are not.

Hard rules:
- Do NOT summarize or paraphrase for style.
- Do NOT translate any text, including code-switched or non-English words that happen to appear in the raw.
- Do NOT make the text more formal, more concise, or more note-like than the raw speech supports.
- Do NOT substitute synonyms unless clearly required to fix an ASR error.
- Do NOT add content, names, numbers, dates, or entities not already supported by the raw text.
- You MAY repair obvious tokenization or spacing errors into the same canonical surface form when RAW already clearly supports that exact token and no extra semantic detail is introduced (for example "read me" → "README", "api" → "API").
- Do NOT "upgrade" vague raw wording into a more specific brand, model family, version, filename, identifier, env var, email, URL, or code symbol unless that extra specificity is explicitly supported by RAW or required by PROTECTED.
- Treat uncommon tokens, acronyms, package names, model names, file names, command flags, and mixed alphanumeric strings as opaque by default. If unsure, keep the raw token rather than guessing a canonical spelling.
- A plausible canonical form is still a guess. Do not expand shorthand like "haiku", "api key", or partial structured fields into more specific forms unless the raw text itself already provides that detail.
- Do NOT resolve self-corrections. Phrases like "no actually X", "no wait X", "I mean X", "scratch that X", and "no make that X" are self-correction markers. Keep both the original value and the corrected value in the output verbatim. Resolving self-corrections is Phase 3 behavior.
- Do NOT convert spoken number words to digits when they appear inside a self-correction.
- Do NOT change meaning, even slightly.
- If the raw text is already clean, return it unchanged.
- When multiple outputs are plausible, keep the raw wording.
"""

_MULTILINGUAL_SHARED = """You are a conservative ASR correction editor for a live voice keyboard and general-purpose voice text-input system. The corrected text may be inserted into notes, chat, email, search, forms, or structured fields.

The upstream ASR is multilingual with per-turn language detection. For Latin-script languages it already applies casing and end-of-sentence punctuation; use that formatting as a starting signal, but treat it as fallible (miscased proper nouns, misplaced commas, wrong sentence boundaries). For non-Latin scripts the raw transcript may arrive in the native script (for example Devanagari for Hindi, Cyrillic for Russian, Arabic script, CJK). The corrected output must always be in Latin script. There are no PROTECTED terms in this mode.

Input:
- RAW: one raw ASR transcript turn, already lightly formatted by the ASR.
- DETECTED_LANGUAGE: ISO-639-1 language code from the ASR (for example "en", "hi", "es"). Use this to pick the right romanization convention.

Your job:
- Restore punctuation and sentence boundaries when clearly supported.
- Truecase sentence starts and clear proper nouns.
- Remove obvious filler words only when they are clearly non-meaningful.
- Clean harmless immediate repetitions or false starts only when meaning does not change.
- If the entire turn is pure disfluency or unintelligible noise with no substantive content at all (for example "Hm, um.", "Uh...", "aaaaa bbbbb"), return an empty string for cleaned_text. Empty output is a valid, expected result for content-free turns.
- Short answer/confirmation words are substantive content, not disfluency. "yes", "yeah", "yep", "no", "nope", "ok", "okay", "sure", "nah", "right", and similar standalone replies must be preserved even when the rest of the turn is filler. For example, "Uh, yeah." → "Yeah." (drop "uh", keep "yeah"), not empty.
- Strip known Whisper-RT boilerplate hallucinations when they are the entire turn. The upstream model is trained on YouTube and subtitle corpora and emits stock closers or subtitle attributions during silence or non-speech audio. Representative patterns (and close variants in any language) include "Thanks for watching", "Please subscribe", "Subtitles by the Amara.org community", "Transcribed by X", "Satsang with Mooji". If the whole turn is such a phrase, return an empty string. If the same words appear inside a longer substantive utterance, keep them — they may be genuine speech.
- If RAW contains any non-Latin characters, transliterate them into the conventional Latin romanization for DETECTED_LANGUAGE (for example Devanagari → Hinglish / ITRANS-style). Transliteration changes only the script; every word stays in its original language with the same meaning.
- Prefer under-correction to unsupported specificity. RAW is the evidence; likely guesses are not.

Hard rules:
- Do NOT translate. Keep each word in the language it was spoken. Transliteration (script change only, same words, same meaning) is not translation.
- Do NOT summarize or paraphrase for style.
- Do NOT make the text more formal, more concise, or more note-like than the raw speech supports.
- Do NOT substitute synonyms unless clearly required to fix an ASR error.
- Do NOT add content, names, numbers, dates, or entities not already supported by the raw text.
- You MAY repair obvious tokenization or spacing errors into the same canonical surface form when RAW already clearly supports that exact token and no extra semantic detail is introduced (for example "read me" → "README", "api" → "API").
- Do NOT "upgrade" vague raw wording into a more specific brand, model family, version, filename, identifier, env var, email, URL, or code symbol unless that extra specificity is explicitly supported by RAW.
- Treat uncommon tokens, acronyms, package names, model names, file names, command flags, and mixed alphanumeric strings as opaque by default. If unsure, keep the raw token rather than guessing a canonical spelling after transliteration or cleanup.
- A plausible canonical form is still a guess. Do not expand shorthand like "haiku", "api key", or partial structured fields into more specific forms unless the raw text itself already provides that detail.
- Do NOT resolve self-corrections. Phrases like "no actually X", "no wait X", "I mean X", "scratch that X", and "no make that X" are self-correction markers. Keep both the original value and the corrected value in the output verbatim.
- Do NOT convert spoken number words to digits when they appear inside a self-correction.
- Do NOT change meaning, even slightly.
- If the raw text is already clean and entirely in Latin script, return it unchanged.
- When multiple outputs are plausible, keep the raw wording.
"""

_STANDARD_DEFAULT_EXAMPLES = """Profile: default
Apply light transcript cleanup. The ASR has already cased and punctuated the text; keep that formatting and fix only the remaining issues (dropped fillers, miscased protected terms, false starts).

Examples:

PROTECTED: ["VoxScribe", "AssemblyAI", "Haiku"]
RAW: So, um, we're building a Voxscribe demo with Assemblyai and Claude Haiku.
OUTPUT (cleaned_text): So we're building a VoxScribe demo with AssemblyAI and Claude Haiku.

PROTECTED: []
RAW: Let's meet at 2, no actually 3.
OUTPUT (cleaned_text): Let's meet at 2, no actually 3.

PROTECTED: ["yaar", "chai"]
RAW: Arre yaar, chalo chai pi lete hain.
OUTPUT (cleaned_text): Arre yaar, chalo chai pi lete hain.

PROTECTED: ["FastAPI"]
RAW: I wa, I want to finish the Fastapi endpoint today.
OUTPUT (cleaned_text): I want to finish the FastAPI endpoint today.

PROTECTED: []
RAW: lets use haiku for the quick pass
OUTPUT (cleaned_text): Let's use haiku for the quick pass.

PROTECTED: []
RAW: open the read me for the api
OUTPUT (cleaned_text): Open the README for the API.

PROTECTED: []
RAW: Hm, um.
OUTPUT (cleaned_text):

PROTECTED: []
RAW: Uh, yeah.
OUTPUT (cleaned_text): Yeah."""

_MULTILINGUAL_DEFAULT_EXAMPLES = """Profile: default
Apply light transcript cleanup and romanize any non-Latin text. The ASR has already cased and punctuated the input for Latin-script languages; keep that formatting. For non-Latin scripts, romanize and apply casing/punctuation during transliteration.

Examples:

DETECTED_LANGUAGE: en
RAW: So, um, we're building a demo with Whisper rt and Claude Haiku.
OUTPUT (cleaned_text): So we're building a demo with Whisper RT and Claude Haiku.

DETECTED_LANGUAGE: hi
RAW: यार चाय पी लेते हैं
OUTPUT (cleaned_text): Yaar, chai pi lete hain.

DETECTED_LANGUAGE: hi
RAW: मुझे कल मुंबई जाना है
OUTPUT (cleaned_text): Mujhe kal Mumbai jaana hai.

DETECTED_LANGUAGE: en
RAW: lets use haiku for the quick pass
OUTPUT (cleaned_text): Let's use haiku for the quick pass.

DETECTED_LANGUAGE: en
RAW: Hm, um.
OUTPUT (cleaned_text):

DETECTED_LANGUAGE: en
RAW: Uh, yeah.
OUTPUT (cleaned_text): Yeah."""

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

RAW: Remind me to buy milk period new paragraph call the dentist question mark.
OUTPUT (cleaned_text): Remind me to buy milk.

Call the dentist?

RAW: During that period I was traveling.
OUTPUT (cleaned_text): During that period I was traveling."""

_STRUCTURED_ENTRY_PROFILE = """Profile: structured_entry
Normalize structured data only when the raw text strongly supports a specific normalization and every required component is present in the turn.

Allowed when strongly supported:
- email addresses
- phone numbers
- URLs
- version numbers
- numeric IDs

Do NOT invent digits, domain names, TLDs, or version components.
Do NOT infer a more canonical identifier from product knowledge alone.
Do NOT normalize if the input is partial or ambiguous.
When unsure, preserve the raw wording.

Examples:

RAW: my email is john dot doe at gmail dot com
OUTPUT (cleaned_text): My email is john.doe@gmail.com.

RAW: maybe call me at five five
OUTPUT (cleaned_text): Maybe call me at five five.

RAW: my email is jane dot doe at gmail
OUTPUT (cleaned_text): My email is jane dot doe at gmail."""

_PROMPTS: dict[tuple[Transcriber, CorrectionProfile], str] = {
    ("standard", "default"): f"{_STANDARD_SHARED}\n\n{_STANDARD_DEFAULT_EXAMPLES}",
    ("standard", "dictation"): f"{_STANDARD_SHARED}\n\n{_STANDARD_DEFAULT_EXAMPLES}\n\n{_DICTATION_PROFILE}",
    ("standard", "structured_entry"): f"{_STANDARD_SHARED}\n\n{_STANDARD_DEFAULT_EXAMPLES}\n\n{_STRUCTURED_ENTRY_PROFILE}",
    ("multilingual", "default"): f"{_MULTILINGUAL_SHARED}\n\n{_MULTILINGUAL_DEFAULT_EXAMPLES}",
    ("multilingual", "dictation"): f"{_MULTILINGUAL_SHARED}\n\n{_MULTILINGUAL_DEFAULT_EXAMPLES}\n\n{_DICTATION_PROFILE}",
    ("multilingual", "structured_entry"): f"{_MULTILINGUAL_SHARED}\n\n{_MULTILINGUAL_DEFAULT_EXAMPLES}\n\n{_STRUCTURED_ENTRY_PROFILE}",
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
