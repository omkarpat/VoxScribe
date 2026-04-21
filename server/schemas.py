from pydantic import BaseModel


class VocabularyInput(BaseModel):
    keyterms_prompt: list[str] = []


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
    turns: list[TurnInput]


class Segment(BaseModel):
    id: str
    source_turn_orders: list[int]
    text: str


class CorrectResponse(BaseModel):
    segments: list[Segment]
