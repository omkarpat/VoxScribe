import logging
from typing import Any, Literal

from pydantic import BaseModel, field_validator

logger = logging.getLogger(__name__)

CorrectionProfile = Literal["default", "dictation"]
Transcriber = Literal["standard", "multilingual"]


class VocabularyInput(BaseModel):
    keyterms_prompt: list[str] = []
    transcriber: Transcriber = "standard"


class TokenResponse(BaseModel):
    provider: str
    token: str
    ws_url: str
    sample_rate: int
    expires_in_seconds: int


class TurnInput(BaseModel):
    turn_order: int
    transcript: str


class CorrectRequest(BaseModel):
    session_id: str
    vocabulary_revision: int
    protected_terms: list[str]
    profile: CorrectionProfile = "default"
    transcriber: Transcriber = "standard"
    detected_language: str | None = None
    turns: list[TurnInput]

    @field_validator("profile", mode="before")
    @classmethod
    def _alias_retired_profiles(cls, value: Any) -> Any:
        # structured_entry was folded into default; accept it from older clients
        # during one compatibility window.
        if value == "structured_entry":
            logger.warning("received deprecated profile=structured_entry; aliasing to default")
            return "default"
        return value


class Segment(BaseModel):
    id: str
    source_turn_orders: list[int]
    text: str


class CorrectResponse(BaseModel):
    segments: list[Segment]
