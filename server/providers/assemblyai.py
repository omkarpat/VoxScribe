import json
import logging
from urllib.parse import urlencode

import httpx
from fastapi import HTTPException

from schemas import TokenResponse, VocabularyInput

logger = logging.getLogger(__name__)

DEFAULT_TOKEN_URL = "https://streaming.assemblyai.com/v3/token"
DEFAULT_WS_URL = "wss://streaming.assemblyai.com/v3/ws"
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_EXPIRES_SECONDS = 600


class AssemblyAIProvider:
    name = "assemblyai"

    def __init__(
        self,
        api_key: str,
        token_url: str = DEFAULT_TOKEN_URL,
        ws_url: str = DEFAULT_WS_URL,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
        expires_in_seconds: int = DEFAULT_EXPIRES_SECONDS,
    ):
        self._api_key = api_key
        self._token_url = token_url
        self._ws_url = ws_url
        self._sample_rate = sample_rate
        self._expires_in_seconds = expires_in_seconds

    async def issue_token(self, vocabulary: VocabularyInput) -> TokenResponse:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(
                self._token_url,
                params={"expires_in_seconds": self._expires_in_seconds},
                headers={"Authorization": self._api_key},
            )
        if resp.status_code != 200:
            logger.error(
                "AssemblyAI token request failed: status=%d body=%s",
                resp.status_code,
                resp.text[:200],
            )
            raise HTTPException(status_code=502, detail="AssemblyAI token request failed")

        data = resp.json()
        token = data["token"]
        expires = data.get("expires_in_seconds", self._expires_in_seconds)

        params: dict[str, str | int] = {
            "sample_rate": self._sample_rate,
            "token": token,
            "format_turns": "true",
        }
        if vocabulary.transcriber == "multilingual":
            # Whisper-RT: 99-language automatic detection. Does not accept
            # `language` or `keyterms_prompt`.
            params["speech_model"] = "whisper-rt"
            params["language_detection"] = "true"
        else:
            params["speech_model"] = "u3-rt-pro"
            if vocabulary.keyterms_prompt:
                params["keyterms_prompt"] = json.dumps(vocabulary.keyterms_prompt)

        return TokenResponse(
            provider=self.name,
            token=token,
            ws_url=f"{self._ws_url}?{urlencode(params)}",
            sample_rate=self._sample_rate,
            expires_in_seconds=expires,
        )
