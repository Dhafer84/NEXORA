import json
from pathlib import Path
from typing import Any

import httpx

from app.ai.base import ProviderError, ProviderReply, ToolCall
from app.config import Settings

MAX_RESPONSE_BYTES = 1_000_000


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
        try:
            response = self.client.post(
                self.base_url + "/chat/completions",
                json=payload,
                headers={"Authorization": f"Bearer {key}"},
                timeout=timeout,
            )
        except httpx.TimeoutException:
            raise ProviderError("timeout", "Le fournisseur IA n’a pas répondu à temps") from None
        except httpx.HTTPError:
            raise ProviderError("unavailable", "Fournisseur IA injoignable") from None
        # Response bodies are never logged or returned: they may echo request data.
        if response.status_code in (401, 403):
            raise ProviderError("auth", "Clé du fournisseur IA refusée")
        if response.status_code == 429:
            raise ProviderError("rate_limited", "Quota ou limite de débit du fournisseur atteint")
        if response.status_code >= 500:
            raise ProviderError("unavailable", "Fournisseur IA temporairement indisponible")
        if response.status_code != 200:
            raise ProviderError(
                "rejected", f"Requête refusée par le fournisseur (HTTP {response.status_code})"
            )
        if len(response.content) > MAX_RESPONSE_BYTES:
            raise ProviderError("bad_response", "Réponse du fournisseur trop volumineuse")
        return _parse(response.content)


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
