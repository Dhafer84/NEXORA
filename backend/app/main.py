import logging
import platform
from pathlib import Path

import psutil
import psycopg
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.ai.engine import AssistantEngine
from app.ai.factory import build_provider
from app.api import router
from app.config import Settings
from app.database import check_database
from app.metrics import ServerMetrics, collect_metrics
from app.security import require_api_key
from app.tools.builtin import build_registry
from app.tools.service import ToolService

logger = logging.getLogger("nexora")


class Health(BaseModel):
    status: str


class BodyLimit:
    """Reject request bodies above a fixed size, declared or streamed."""

    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        too_large = JSONResponse({"detail": "Requête trop volumineuse"}, status_code=413)
        for name, value in scope.get("headers", []):
            if name == b"content-length" and (not value.isdigit() or int(value) > self.max_bytes):
                return await too_large(scope, receive, send)
        # Read the (small) body first so a streamed oversize body never reaches the route.
        chunks, size = [], 0
        while True:
            message = await receive()
            if message["type"] != "http.request":
                return
            chunks.append(message.get("body", b""))
            size += len(chunks[-1])
            if size > self.max_bytes:
                return await too_large(scope, receive, send)
            if not message.get("more_body", False):
                break
        body = b"".join(chunks)
        replayed = False

        async def replay() -> Message:
            nonlocal replayed
            if replayed:
                return await receive()
            replayed = True
            return {"type": "http.request", "body": body, "more_body": False}

        await self.app(scope, replay, send)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    if settings.nexora_metrics_scope == "host":
        if platform.system() != "Linux":
            raise RuntimeError("Les métriques hôte nécessitent Linux")
        for name in ("stat", "meminfo"):
            if not (Path(settings.nexora_procfs_path) / name).is_file():
                raise RuntimeError("Les sources de métriques hôte sont absentes")
        if not Path(settings.nexora_disk_path).is_dir():
            raise RuntimeError("Le point de mesure du disque est absent")
    # One configuration per process, set before serving requests.
    psutil.PROCFS_PATH = settings.nexora_procfs_path
    app = FastAPI(title="NEXORA", version="0.2.0", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.tools = ToolService(settings, build_registry())
    provider = build_provider(settings)
    # The assistant is optional: health and metrics never depend on it.
    app.state.engine = AssistantEngine(settings, app.state.tools, provider) if provider else None
    app.add_middleware(BodyLimit, max_bytes=settings.nexora_max_request_bytes)

    @app.exception_handler(psycopg.Error)
    async def database_error(_: Request, error: psycopg.Error) -> JSONResponse:
        # Class name only: driver messages can contain connection details.
        logger.warning("database_error type=%s", type(error).__name__)
        return JSONResponse(
            {"detail": {"code": "database_unavailable", "message": "Base de données indisponible"}},
            status_code=503,
        )

    @app.get("/health/live", response_model=Health, tags=["health"])
    def live() -> Health:
        return Health(status="ok")

    @app.get(
        "/health/ready",
        response_model=Health,
        dependencies=[Depends(require_api_key)],
        tags=["health"],
    )
    def ready() -> Health:
        try:
            check_database(settings)
        except psycopg.Error:
            # Do not log connection strings, credentials or database exceptions.
            logger.warning("database_check_failed")
            raise HTTPException(503, "Base de données indisponible") from None
        return Health(status="ready")

    @app.get(
        "/api/v1/server/metrics",
        response_model=ServerMetrics,
        dependencies=[Depends(require_api_key)],
        tags=["server"],
    )
    def metrics() -> ServerMetrics:
        try:
            return collect_metrics(settings)
        except (OSError, ValueError, psutil.Error):
            logger.warning("metrics_collection_failed")
            raise HTTPException(503, "Métriques indisponibles") from None

    @app.get("/api/v1/auth/check", dependencies=[Depends(require_api_key)], tags=["auth"])
    def auth_check() -> dict[str, str]:
        return {"status": "authenticated"}

    app.include_router(router)
    return app
