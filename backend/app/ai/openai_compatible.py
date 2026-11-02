import json
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from pathlib import Path
from typing import Any

import httpx

from app.ai.base import ProviderError, ProviderReply, ToolCall
from app.config import Settings

MAX_RESPONSE_BYTES = 1_000_000
# httpx timeouts apply per operation (connect, each read); the pool enforces a total cap.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="nexora-ai")


class _Deadline(Exception):
    pass


class _TooLarge(Exception):
    pass


class OpenAICompatibleProvider:
    """Chat Completions API with tool calls (NVIDIA NIM, xAI Grok, OpenAI…)."""

    real = True

    def __init__(self, settings: Settings, client: httpx.Client | None = None) -> None:
        self.name = "openai_compatible"
        self.model = settings.nexora_ai_model
        self.base_url = settings.nexora_ai_base_url
        self.key_file = Path(settings.nexora_ai_api_key_file)
        self.max_tokens = settings.nexora_ai_max_output_tokens
        self.client = client or httpx.Client(follow_redirects=False)

    def _key(self) -> str | None:
        # Read on each call so a rotated key file applies without a restart.
        try:
            key = self.key_file.read_text().strip()
        except OSError:
            return None
        return key or None

    def configured(self) -> bool:
        return self._key() is not None

    def complete(
        self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], timeout: float
    ) -> ProviderReply:
        key = self._key()
        if key is None:
            raise ProviderError("not_configured", "Clé du fournisseur IA absente")
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "max_tokens": self.max_tokens,
            "temperature": 0.2,
        }
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        deadline = time.monotonic() + timeout
        future = _pool.submit(self._post, key, payload, timeout, deadline)
        try:
            status_code, content = future.result(timeout=timeout)
        except (FutureTimeout, _Deadline, httpx.TimeoutException):
            raise ProviderError("timeout", "Le fournisseur IA n’a pas répondu à temps") from None
        except _TooLarge:
            raise ProviderError("bad_response", "Réponse du fournisseur trop volumineuse") from None
        except httpx.HTTPError:
            raise ProviderError("unavailable", "Fournisseur IA injoignable") from None
        # Response bodies are never logged or returned: they may echo request data.
        if status_code in (401, 403):
            raise ProviderError("auth", "Clé du fournisseur IA refusée")
        if status_code == 429:
            raise ProviderError("rate_limited", "Quota ou limite de débit du fournisseur atteint")
        if status_code >= 500:
            raise ProviderError("unavailable", "Fournisseur IA temporairement indisponible")
        if status_code != 200:
            raise ProviderError(
                "rejected", f"Requête refusée par le fournisseur (HTTP {status_code})"
            )
        return _parse(content)

    def _post(
        self, key: str, payload: dict[str, Any], timeout: float, deadline: float
    ) -> tuple[int, bytes]:
        # Streamed so that size and total duration are checked while reading.
        with self.client.stream(
            "POST",
            self.base_url + "/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {key}"},
            timeout=timeout,
        ) as response:
            chunks, size = [], 0
            for chunk in response.iter_bytes():
                size += len(chunk)
                if size > MAX_RESPONSE_BYTES:
                    raise _TooLarge()
                if time.monotonic() > deadline:
                    raise _Deadline()
                chunks.append(chunk)
            return response.status_code, b"".join(chunks)


def _parse(content: bytes) -> ProviderReply:
    try:
        message = json.loads(content)["choices"][0]["message"]
        calls = [
            ToolCall(
                id=str(call["id"]),
                name=str(call["function"]["name"]),
                arguments=call["function"].get("arguments") or "{}",
            )
            for call in message.get("tool_calls") or []
        ]
        text = message.get("content") or ""
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        raise ProviderError("bad_response", "Réponse du fournisseur illisible") from None
    if not isinstance(text, str) or not all(isinstance(c.arguments, str) for c in calls):
        raise ProviderError("bad_response", "Réponse du fournisseur illisible")
    return ProviderReply(text=text, tool_calls=calls)
