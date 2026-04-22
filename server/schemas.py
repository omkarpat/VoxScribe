from typing import Literal

from pydantic import BaseModel

CorrectionProfile = Literal["default", "dictation", "structured_entry"]
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


class Segment(BaseModel):
    id: str
    source_turn_orders: list[int]
    text: str


class CorrectResponse(BaseModel):
    segments: list[Segment]
