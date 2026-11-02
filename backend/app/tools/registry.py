import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Literal

from pydantic import BaseModel

from app.config import Settings

Risk = Literal["low", "medium", "high"]
TOOL_NAME = re.compile(r"^[a-z][a-z0-9_]{2,63}$")


@dataclass(frozen=True)
class ToolContext:
    settings: Settings


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    parameters: type[BaseModel]
    result: type[BaseModel]
    permissions: frozenset[str]
    risk: Risk
    requires_approval: bool
    timeout_seconds: float
    handler: Callable[[ToolContext, Any], BaseModel]
    # Human-readable sentence shown when asking for approval.
    summarize: Callable[[Any], str]

    def public(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters_schema": self.parameters.model_json_schema(),
            "result_schema": self.result.model_json_schema(),
            "permissions": sorted(self.permissions),
            "risk": self.risk,
            "requires_approval": self.requires_approval,
            "timeout_seconds": self.timeout_seconds,
        }

    def function_schema(self) -> dict[str, Any]:
        # OpenAI-compatible function declaration; only these tools reach the model.
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters.model_json_schema(),
            },
        }


class ToolRegistry:
    def __init__(self) -> None:
        self._tools: dict[str, ToolSpec] = {}

    def register(self, spec: ToolSpec) -> ToolSpec:
        if not TOOL_NAME.match(spec.name):
            raise ValueError(f"Nom d’outil invalide : {spec.name}")
        if spec.name in self._tools:
            raise ValueError(f"Outil déjà enregistré : {spec.name}")
        if not spec.permissions:
            raise ValueError("Un outil doit déclarer au moins une permission")
        if not 0 < spec.timeout_seconds <= 60:
            raise ValueError("Délai d’exécution hors limites")
        if spec.risk != "low" and not spec.requires_approval:
            raise ValueError("Un outil à risque doit exiger une validation")
        self._tools[spec.name] = spec
        return spec

    def get(self, name: str) -> ToolSpec | None:
        return self._tools.get(name)

    def all(self) -> list[ToolSpec]:
        return sorted(self._tools.values(), key=lambda spec: spec.name)

    def allowed(self, permissions: frozenset[str]) -> list[ToolSpec]:
        return [spec for spec in self.all() if spec.permissions <= permissions]
