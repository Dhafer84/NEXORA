import json
from typing import Any

from app.ai.base import ProviderReply, ToolCall

ANALYSIS_PROMPT = "Tu reçois un résumé chiffré d’activité"

KEYWORDS = {
    "server_metrics": ("cpu", "processeur", "mémoire", "memoire", "ram", "disque", "métrique"),
    "database_status": ("base", "postgres", "donnée"),
    "test_action": ("test",),
}


class SimulatedProvider:
    """Deterministic keyword matcher for tests and demos. Not an AI model."""

    name = "simulated"
    model = "keyword-rules"
    real = False

    def configured(self) -> bool:
        return True

    def complete(
        self, messages: list[dict[str, Any]], tools: list[dict[str, Any]], timeout: float
    ) -> ProviderReply:
        last = messages[-1]
        if not tools and str(messages[0].get("content", "")).startswith(ANALYSIS_PROMPT):
            # Isolated activity analysis (app/analysis.py): fixed text.
            return ProviderReply(
                text=f"Analyse simulée d’un résumé de {len(str(last.get('content', '')))} "
                "caractères. Aucune IA réelle n’a été contactée."
            )
        if last["role"] == "tool":
            return ProviderReply(text="Résultat de l’outil : " + last["content"])
        text = str(last.get("content", "")).lower()
        exposed = {tool["function"]["name"] for tool in tools}
        for name, words in KEYWORDS.items():
            if name in exposed and any(word in text for word in words):
                arguments = {"label": "demo", "value": 1} if name == "test_action" else {}
                return ProviderReply(
                    text="", tool_calls=[ToolCall("sim-1", name, json.dumps(arguments))]
                )
        return ProviderReply(text="Aucune règle simulée ne correspond à cette demande.")
