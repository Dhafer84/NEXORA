"""Activity analysis: one isolated request to the AI provider.

The phone sends a summary it computed and showed to the user, together with
the recipient the user confirmed. The request has no tools and no history,
and nothing is stored: no conversation, no message, no log of its content.
"""

import logging
from typing import Annotated
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from app.ai.base import ProviderError
from app.ai.engine import SIMULATION_NOTICE, AssistantEngine, ProviderInfo
from app.api import Caller

logger = logging.getLogger("nexora.analysis")
router = APIRouter(prefix="/api/v1/analysis", tags=["analysis"])

MAX_SUMMARY_CHARS = 6000

SYSTEM_PROMPT = (
    "Tu reçois un résumé chiffré d’activité physique et de sommeil, calculé par "
    "l’application NEXORA sur le téléphone de l’utilisateur. Réponds en français, en "
    "200 mots au plus. Décris les tendances de façon factuelle et cite la période "
    "analysée. Les chiffres du résumé font foi : n’en calcule pas d’autres et n’en "
    "invente aucun. Distingue clairement les jours sans donnée ou partiels, et dis "
    "quand une comparaison serait trompeuse (couverture différente ou insuffisante). "
    "Ne formule aucun diagnostic, aucune recommandation médicale et aucune cause que "
    "le résumé ne mentionne pas. Si les données sont insuffisantes, dis-le simplement."
)


class Recipient(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    model: str


class RecipientView(BaseModel):
    provider: ProviderInfo | None
    configured: bool
    # Host the summary would be sent to by the backend, e.g. integrate.api.nvidia.com.
    destination: str | None
    label: str
    stored: bool = False


class AnalysisRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    summary: Annotated[str, Field(min_length=1, max_length=MAX_SUMMARY_CHARS)]
    recipient: Recipient


class AnalysisResult(BaseModel):
    text: str
    provider: ProviderInfo
    destination: str | None
    simulated: bool


def _destination(engine: AssistantEngine) -> str | None:
    if not engine.provider.real:
        return None
    base_url = getattr(engine.provider, "base_url", None)
    return urlsplit(base_url).hostname if base_url else None


def _label(engine: AssistantEngine | None) -> str:
    if engine is None:
        return "Aucun fournisseur IA configuré"
    if not engine.provider.real:
        return "Fournisseur simulé du serveur NEXORA (aucune IA réelle)"
    host = _destination(engine) or ""
    vendor = "NVIDIA" if "nvidia" in host else host
    return f"{vendor} — modèle {engine.info.model}"


@router.get("/recipient", response_model=RecipientView)
def recipient(_: Caller, request: Request):
    """Who would receive an analysis request, without contacting it."""
    engine: AssistantEngine | None = request.app.state.engine
    return RecipientView(
        provider=engine.info if engine else None,
        configured=bool(engine and engine.provider.configured()),
        destination=_destination(engine) if engine else None,
        label=_label(engine),
    )


@router.post("/activity", response_model=AnalysisResult)
def analyse_activity(body: AnalysisRequest, _: Caller, request: Request):
    engine: AssistantEngine | None = request.app.state.engine
    if engine is None or not engine.provider.configured():
        raise HTTPException(
            503, {"code": "ai_not_configured", "message": "Fournisseur IA non configuré"}
        )
    # The user confirmed one recipient: any other one needs a new confirmation.
    if (body.recipient.name, body.recipient.model) != (engine.info.name, engine.info.model):
        raise HTTPException(
            409,
            {
                "code": "recipient_changed",
                "message": "Le fournisseur IA du serveur a changé : nouvelle confirmation "
                "nécessaire",
                "recipient": _label(engine),
            },
        )
    settings = request.app.state.settings
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": body.summary},
    ]
    try:
        reply = engine.provider.complete(messages, [], settings.nexora_ai_timeout_seconds)
    except ProviderError as error:
        logger.warning("activity_analysis_failed code=%s", error.code)
        raise HTTPException(503, {"code": f"ai_{error.code}", "message": error.message}) from None
    text = reply.text.strip()
    if not text:
        raise HTTPException(
            503, {"code": "ai_bad_response", "message": "Réponse vide du fournisseur IA"}
        )
    # Only sizes are logged: never the summary nor the reply.
    logger.info(
        "activity_analysis status=ok chars_in=%d chars_out=%d", len(body.summary), len(text)
    )
    simulated = not engine.provider.real
    return AnalysisResult(
        text=(SIMULATION_NOTICE + text) if simulated else text,
        provider=engine.info,
        destination=_destination(engine),
        simulated=simulated,
    )
