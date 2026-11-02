from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass(frozen=True)
class ToolCall:
    id: str
    name: str
    arguments: str  # Raw JSON text produced by the model, validated by the backend.


@dataclass(frozen=True)
class ProviderReply:
    text: str
    tool_calls: list[ToolCall] = field(default_factory=list)


class ProviderError(Exception):
    """Provider failure; ``message`` is safe to show and never contains credentials."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class AIProvider(Protocol):
    name: str
    model: str
    real: bool  # False for the simulator: it must never be presented as an AI.

    def configured(self) -> bool: ...

    def complete(
        self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], timeout: float
    ) -> ProviderReply: ...
