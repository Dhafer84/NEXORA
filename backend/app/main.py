import logging
import platform
from pathlib import Path

import psutil
import psycopg
from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel

from app.config import Settings
from app.database import check_database
from app.metrics import ServerMetrics, collect_metrics
from app.security import require_api_key

logger = logging.getLogger("nexora")


class Health(BaseModel):
    status: str


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
    app = FastAPI(title="NEXORA", version="0.1.0", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings

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

    return app
