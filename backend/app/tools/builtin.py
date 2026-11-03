from datetime import datetime, timezone
from typing import Literal

import psycopg
from pydantic import BaseModel, ConfigDict, Field

from app.database import check_database, connect
from app.github import GitHubReader, GitHubReport
from app.metrics import ServerMetrics, collect_metrics
from app.tools.registry import ToolContext, ToolRegistry, ToolSpec


class NoParameters(BaseModel):
    model_config = ConfigDict(extra="forbid")


class DatabaseStatus(BaseModel):
    available: bool
    schema_version: int | None = None
    checked_at: datetime


class ActionTestParameters(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str = Field(min_length=1, max_length=80, pattern=r"^[\w .,'’-]+$")
    value: int = Field(ge=0, le=1000)


class ActionTestResult(BaseModel):
    acknowledged: Literal[True] = True
    label: str
    value: int
    executed_at: datetime
    effect: str = "Aucun effet sur le serveur : action de démonstration"


def server_metrics(context: ToolContext, _: NoParameters) -> ServerMetrics:
    return collect_metrics(context.settings)


def database_status(context: ToolContext, _: NoParameters) -> DatabaseStatus:
    now = datetime.now(timezone.utc)
    try:
        check_database(context.settings)
        with connect(context.settings, read_only=True) as connection:
            row = connection.execute(
                "SELECT coalesce(max(version), 0) AS version FROM schema_migrations"
            ).fetchone()
    except psycopg.Error:
        return DatabaseStatus(available=False, checked_at=now)
    return DatabaseStatus(available=True, schema_version=row["version"], checked_at=now)


def test_action(_: ToolContext, params: ActionTestParameters) -> ActionTestResult:
    return ActionTestResult(
        label=params.label, value=params.value, executed_at=datetime.now(timezone.utc)
    )


def build_registry(github: GitHubReader | None = None) -> ToolRegistry:
    registry = ToolRegistry()
    if github is not None and github.repos:
        registry.register(
            ToolSpec(
                name="github_report",
                description=(
                    "Résume les dépôts GitHub autorisés : derniers commits, issues ouvertes "
                    "et résultats GitHub Actions. Lecture seule, dépôts de la liste "
                    "autorisée uniquement."
                ),
                parameters=NoParameters,
                result=GitHubReport,
                permissions=frozenset({"github:read"}),
                risk="low",
                requires_approval=False,
                timeout_seconds=45,
                handler=lambda _context, _params: github.report(),
                summarize=lambda _: "Lire l’état des dépôts GitHub autorisés",
            )
        )
    registry.register(
        ToolSpec(
            name="server_metrics",
            description=(
                "Lit l’utilisation actuelle du processeur, de la mémoire et du disque "
                "du serveur NEXORA. Lecture seule."
            ),
            parameters=NoParameters,
            result=ServerMetrics,
            permissions=frozenset({"server:read"}),
            risk="low",
            requires_approval=False,
            timeout_seconds=5,
            handler=server_metrics,
            summarize=lambda _: "Lire les métriques du serveur",
        )
    )
    registry.register(
        ToolSpec(
            name="database_status",
            description=(
                "Vérifie si la base PostgreSQL de NEXORA répond et indique la version "
                "de son schéma. Lecture seule."
            ),
            parameters=NoParameters,
            result=DatabaseStatus,
            permissions=frozenset({"database:read"}),
            risk="low",
            requires_approval=False,
            timeout_seconds=5,
            handler=database_status,
            summarize=lambda _: "Vérifier la disponibilité de la base",
        )
    )
    registry.register(
        ToolSpec(
            name="test_action",
            description=(
                "Action de démonstration soumise à validation humaine. Elle n’a aucun "
                "effet sur le serveur ; elle sert à tester le circuit d’approbation."
            ),
            parameters=ActionTestParameters,
            result=ActionTestResult,
            permissions=frozenset({"test:execute"}),
            risk="medium",
            requires_approval=True,
            timeout_seconds=5,
            handler=test_action,
            summarize=lambda p: (
                f"Exécuter l’action de test « {p.label} » avec la valeur {p.value} "
                "(aucun effet sur le serveur)"
            ),
        )
    )
    return registry
