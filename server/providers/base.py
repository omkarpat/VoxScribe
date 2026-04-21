from typing import Protocol, runtime_checkable

from schemas import TokenResponse, VocabularyInput


@runtime_checkable
class StreamingProvider(Protocol):
    """Contract a streaming ASR provider must satisfy for VoxScribe.

    A provider is responsible for (1) minting a short-lived client token and
    (2) returning a fully-formed WebSocket URL the iOS client can open without
    knowing provider-specific query-string conventions. Everything provider-
    specific (endpoint, speech model, turn formatting, keyterm biasing) must
    be baked into the returned URL — the client just opens it.
    """

    name: str

    async def issue_token(self, vocabulary: VocabularyInput) -> TokenResponse: ...
