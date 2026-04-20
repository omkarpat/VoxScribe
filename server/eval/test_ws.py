"""Quick diagnostic: fetch an AssemblyAI temp token and try to connect the WS.
Prints the full handshake response on failure so we can see the real error."""

import asyncio
import json
import os
import sys
from urllib.parse import urlencode

import httpx
import websockets
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "..", ".env"), override=True)

ASSEMBLYAI_API_KEY = os.environ["ASSEMBLYAI_API_KEY"]
TOKEN_URL = "https://streaming.assemblyai.com/v3/token?expires_in_seconds=600"
WS_BASE = "wss://streaming.assemblyai.com/v3/ws"

KEYTERMS = ["Anthropic", "Claude", "Haiku", "AssemblyAI", "VoxScribe"]


async def main():
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.get(TOKEN_URL, headers={"Authorization": ASSEMBLYAI_API_KEY})
        r.raise_for_status()
        token = r.json()["token"]
    print(f"got token: len={len(token)}")

    params = {
        "speech_model": "u3-rt-pro",
        "sample_rate": 16000,
        "token": token,
        "format_turns": "true",
        "keyterms_prompt": json.dumps(KEYTERMS),
    }
    url = f"{WS_BASE}?{urlencode(params)}"
    print(f"connecting to {url[:120]}…")

    try:
        async with websockets.connect(url) as ws:
            print("WS connected. waiting for Begin…")
            msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
            print(f"received: {msg[:200]}")
            await ws.send(json.dumps({"type": "Terminate"}))
            try:
                term = await asyncio.wait_for(ws.recv(), timeout=2.0)
                print(f"termination: {term[:200]}")
            except asyncio.TimeoutError:
                print("(no termination frame before close)")
    except websockets.exceptions.InvalidStatusCode as e:
        print(f"HTTP rejection status={e.status_code}")
        if hasattr(e, "headers"):
            print(f"headers: {dict(e.headers)}")
    except Exception as e:
        print(f"connect failed: {type(e).__name__}: {e}")


if __name__ == "__main__":
    asyncio.run(main())
