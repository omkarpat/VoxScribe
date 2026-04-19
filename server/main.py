import logging
import os
import sys

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException

from correction import correct_single_turn
from schemas import CorrectRequest, CorrectResponse, Segment, TokenResponse

load_dotenv(override=True)

REQUIRED_ENV = ("ASSEMBLYAI_API_KEY", "ANTHROPIC_API_KEY")
missing = [name for name in REQUIRED_ENV if not os.getenv(name)]
if missing:
    sys.exit(f"Missing required env vars: {', '.join(missing)}. See server/.env.example.")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("voxscribe")

ASSEMBLYAI_API_KEY = os.environ["ASSEMBLYAI_API_KEY"]
ASSEMBLYAI_TOKEN_URL = "https://streaming.assemblyai.com/v3/token"
TOKEN_EXPIRES_SECONDS = 600

app = FastAPI(title="VoxScribe")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/token", response_model=TokenResponse)
async def token():
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            ASSEMBLYAI_TOKEN_URL,
            params={"expires_in_seconds": TOKEN_EXPIRES_SECONDS},
            headers={"Authorization": ASSEMBLYAI_API_KEY},
        )
    if resp.status_code != 200:
        logger.error("AssemblyAI token request failed: status=%d body=%s", resp.status_code, resp.text[:200])
        raise HTTPException(status_code=502, detail="AssemblyAI token request failed")
    data = resp.json()
    return TokenResponse(
        token=data["token"],
        expires_in_seconds=data.get("expires_in_seconds", TOKEN_EXPIRES_SECONDS),
    )


@app.post("/correct", response_model=CorrectResponse)
async def correct(req: CorrectRequest):
    if len(req.turns) != 1:
        raise HTTPException(status_code=400, detail="Phase 1 /correct accepts exactly one turn.")

    logger.info(
        "correct session=%s revision=%d protected_terms=%d turn_order=%d",
        req.session_id,
        req.vocabulary_revision,
        len(req.protected_terms),
        req.turns[0].turn_order,
    )

    turn = req.turns[0]
    cleaned = await correct_single_turn(turn.transcript, req.protected_terms)
    segment = Segment(
        id=f"turn-{turn.turn_order}",
        source_turn_orders=[turn.turn_order],
        text=cleaned,
    )
    return CorrectResponse(segments=[segment])
