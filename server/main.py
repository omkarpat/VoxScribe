import logging
import os
import sys

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException

from correction import correct_single_turn
from providers import AssemblyAIProvider, StreamingProvider
from schemas import CorrectRequest, CorrectResponse, Segment, TokenResponse, VocabularyInput

load_dotenv(override=True)

REQUIRED_ENV = ("ASSEMBLYAI_API_KEY", "ANTHROPIC_API_KEY")
missing = [name for name in REQUIRED_ENV if not os.getenv(name)]
if missing:
    sys.exit(f"Missing required env vars: {', '.join(missing)}. See server/.env.example.")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("voxscribe")

provider: StreamingProvider = AssemblyAIProvider(api_key=os.environ["ASSEMBLYAI_API_KEY"])

app = FastAPI(title="VoxScribe")


@app.get("/health")
def health():
    return {"status": "ok", "provider": provider.name}


@app.post("/token", response_model=TokenResponse)
async def token(vocabulary: VocabularyInput):
    return await provider.issue_token(vocabulary)


@app.post("/correct", response_model=CorrectResponse)
async def correct(req: CorrectRequest):
    if len(req.turns) != 1:
        raise HTTPException(status_code=400, detail="/correct accepts exactly one turn (multi-turn is Phase 3).")

    logger.info(
        "correct session=%s revision=%d profile=%s protected_terms=%d turn_order=%d",
        req.session_id,
        req.vocabulary_revision,
        req.profile,
        len(req.protected_terms),
        req.turns[0].turn_order,
    )

    turn = req.turns[0]
    cleaned = await correct_single_turn(turn.transcript, req.protected_terms, req.profile)
    segment = Segment(
        id=f"turn-{turn.turn_order}",
        source_turn_orders=[turn.turn_order],
        text=cleaned,
    )
    return CorrectResponse(segments=[segment])
