from datetime import datetime, timezone
from typing import Literal

import psutil
from pydantic import BaseModel, Field

from app.config import Settings


class Capacity(BaseModel):
    total_bytes: int = Field(ge=0)
    used_bytes: int = Field(ge=0)
    available_bytes: int = Field(ge=0)
    used_percent: float = Field(ge=0, le=100)


class ServerMetrics(BaseModel):
    observed_at: datetime
    scope: Literal["runtime", "host"]
    cpu_percent: float = Field(ge=0, le=100)
    memory: Capacity
    disk: Capacity


def collect_metrics(settings: Settings) -> ServerMetrics:
    cpu = psutil.cpu_percent(interval=0.1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage(settings.nexora_disk_path)
    return ServerMetrics(
        observed_at=datetime.now(timezone.utc),
        scope=settings.nexora_metrics_scope,
        cpu_percent=cpu,
        memory=Capacity(
            total_bytes=memory.total,
            used_bytes=memory.total - memory.available,
            available_bytes=memory.available,
            used_percent=memory.percent,
        ),
        disk=Capacity(
            total_bytes=disk.total,
            used_bytes=disk.used,
            available_bytes=disk.free,
            used_percent=disk.percent,
        ),
    )
