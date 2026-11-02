import hashlib
import json
import logging
import re
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from datetime import datetime
from typing import Any, Literal
from uuid import UUID

import psycopg
from psycopg.types.json import Jsonb
from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.tools.permissions import PermissionDenied, Principal, authorize
from app.tools.registry import ToolContext, ToolRegistry, ToolSpec

logger = logging.getLogger("nexora.tools")

ExecutionStatus = Literal[
    "denied", "invalid", "pending_approval", "running", "succeeded", "failed", "timed_out"
]
ApprovalStatus = Literal["pending", "approved", "rejected", "expired", "consumed"]
MAX_ARGUMENTS_BYTES = 4096
SAFE_NAME = re.compile(r"[^a-zA-Z0-9_.-]")
# Handlers are bounded read-only functions; a timed-out one finishes in the background.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="nexora-tool")


class ToolError(Exception):
    """Refusal with a stable code and a message safe to show to the user."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


class ApprovalView(BaseModel):
    id: UUID
    conversation_id: UUID | None
    tool: str
    arguments: dict[str, Any]
    arguments_hash: str
    summary: str
    risk: str
    status: ApprovalStatus
    expires_at: datetime
    decided_at: datetime | None
    decision_reason: str | None
    consumed_at: datetime | None
    created_at: datetime


class ExecutionView(BaseModel):
    execution_id: UUID
    tool: str
    status: ExecutionStatus
    result: dict[str, Any] | None = None
    error_code: str | None = None
    error_message: str | None = None
    approval: ApprovalView | None = None
    replayed: bool = False


def arguments_hash(tool: str, arguments: dict[str, Any]) -> str:
    canonical = json.dumps(
        {"tool": tool, "arguments": arguments},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def _approval(row: dict[str, Any]) -> ApprovalView:
    return ApprovalView(
        id=row["id"],
        conversation_id=row["conversation_id"],
        tool=row["tool_name"],
        arguments=row["arguments"],
        arguments_hash=row["arguments_hash"],
        summary=row["summary"],
        risk=row["risk_level"],
        status=row["status"],
        expires_at=row["expires_at"],
        decided_at=row["decided_at"],
        decision_reason=row["decision_reason"],
        consumed_at=row["consumed_at"],
        created_at=row["created_at"],
    )


def _execution(row: dict[str, Any], approval: ApprovalView | None = None) -> ExecutionView:
    return ExecutionView(
        execution_id=row["id"],
        tool=row["tool_name"],
        status=row["status"],
        result=row["result"],
        error_code=row["error_code"],
        error_message=row["error_message"],
        approval=approval,
    )


def _validation_message(error: ValidationError) -> str:
    # Field names and error types only: never echo submitted values.
    parts = []
    for item in error.errors(include_input=False, include_url=False)[:5]:
        field = ".".join(str(part) for part in item["loc"]) or "arguments"
        parts.append(f"{field} : {item['msg']}")
    return "Paramètres invalides — " + " ; ".join(parts)


class ToolService:
    def __init__(self, settings: Settings, registry: ToolRegistry) -> None:
        self.settings = settings
        self.registry = registry
        self.context = ToolContext(settings)

    # ----- Validation -------------------------------------------------------

    def _validate(self, spec: ToolSpec, raw: Any) -> BaseModel:
        if raw is None:
            raw = {}
        if not isinstance(raw, dict):
            raise ToolError(422, "invalid_arguments", "Les paramètres doivent être un objet JSON")
        if len(json.dumps(raw, ensure_ascii=False).encode()) > MAX_ARGUMENTS_BYTES:
            raise ToolError(422, "invalid_arguments", "Paramètres trop volumineux")
        try:
            return spec.parameters.model_validate(raw)
        except ValidationError as error:
            raise ToolError(422, "invalid_arguments", _validation_message(error)) from None

    def _record_refusal(
        self,
        connection: psycopg.Connection,
        tool: str,
        status: ExecutionStatus,
        error: ToolError,
        source: str,
        conversation_id: UUID | None,
    ) -> ExecutionView:
        row = connection.execute(
            """INSERT INTO tool_executions
                   (conversation_id, tool_name, source, status, error_code, error_message,
                    finished_at)
               VALUES (%s, %s, %s, %s, %s, %s, now()) RETURNING *""",
            (conversation_id, tool, source, status, error.code, error.message),
        ).fetchone()
        logger.info("tool_refused tool=%s code=%s", tool, error.code)
        return _execution(row)

    # ----- Request ----------------------------------------------------------

    def request(
        self,
        connection: psycopg.Connection,
        principal: Principal,
        name: str,
        raw_arguments: Any,
        *,
        source: Literal["api", "assistant"],
        conversation_id: UUID | None = None,
    ) -> ExecutionView:
        """Check, then either run a tool or create a persistent approval request."""
        spec = self.registry.get(name)
        if spec is None:
            safe = SAFE_NAME.sub("_", str(name))[:64] or "_"
            error = ToolError(404, "unknown_tool", "Outil inconnu ou non autorisé")
            return self._record_refusal(connection, safe, "denied", error, source, conversation_id)
        try:
            authorize(principal, spec)
        except PermissionDenied as denied:
            error = ToolError(403, "permission_denied", str(denied))
            return self._record_refusal(connection, name, "denied", error, source, conversation_id)
        try:
            params = self._validate(spec, raw_arguments)
        except ToolError as error:
            return self._record_refusal(connection, name, "invalid", error, source, conversation_id)

        arguments = params.model_dump(mode="json")
        digest = arguments_hash(spec.name, arguments)
        if spec.requires_approval:
            with connection.transaction():
                approval = connection.execute(
                    """INSERT INTO approval_requests
                           (conversation_id, tool_name, arguments, arguments_hash, summary,
                            risk_level, expires_at)
                       VALUES (%s, %s, %s, %s, %s, %s, now() + make_interval(secs => %s))
                       RETURNING *""",
                    (
                        conversation_id,
                        spec.name,
                        Jsonb(arguments),
                        digest,
                        spec.summarize(params),
                        spec.risk,
                        self.settings.nexora_approval_ttl_seconds,
                    ),
                ).fetchone()
                row = connection.execute(
                    """INSERT INTO tool_executions
                           (conversation_id, approval_request_id, tool_name, arguments,
                            arguments_hash, source, status)
                       VALUES (%s, %s, %s, %s, %s, %s, 'pending_approval') RETURNING *""",
                    (conversation_id, approval["id"], spec.name, Jsonb(arguments), digest, source),
                ).fetchone()
            logger.info("approval_requested tool=%s approval=%s", spec.name, approval["id"])
            return _execution(row, _approval(approval))

        row = connection.execute(
            """INSERT INTO tool_executions
                   (conversation_id, tool_name, arguments, arguments_hash, source, status,
                    started_at)
               VALUES (%s, %s, %s, %s, %s, 'running', now()) RETURNING *""",
            (conversation_id, spec.name, Jsonb(arguments), digest, source),
        ).fetchone()
        return self._run(connection, spec, params, row["id"])

    # ----- Execution --------------------------------------------------------

    def _run(
        self,
        connection: psycopg.Connection,
        spec: ToolSpec,
        params: BaseModel,
        execution_id: UUID,
        approval: ApprovalView | None = None,
    ) -> ExecutionView:
        future = _pool.submit(spec.handler, self.context, params)
        result = None
        error_code = error_message = None
        try:
            output = future.result(timeout=spec.timeout_seconds)
            result = spec.result.model_validate(output).model_dump(mode="json")
            status: ExecutionStatus = "succeeded"
        except FutureTimeout:
            status, error_code = "timed_out", "timeout"
            error_message = f"Délai maximal de {spec.timeout_seconds:g} s dépassé"
        except Exception as error:  # noqa: BLE001 - handler errors are reported, not raised
            status, error_code, error_message = "failed", "tool_failed", "L’outil a échoué"
            logger.warning("tool_failed tool=%s error=%s", spec.name, type(error).__name__)
        row = connection.execute(
            """UPDATE tool_executions
               SET status = %s, result = %s, error_code = %s, error_message = %s,
                   finished_at = now()
               WHERE id = %s RETURNING *""",
            (
                status,
                Jsonb(result) if result is not None else None,
                error_code,
                error_message,
                execution_id,
            ),
        ).fetchone()
        logger.info("tool_finished tool=%s status=%s", spec.name, status)
        return _execution(row, approval)

    # ----- Approvals --------------------------------------------------------

    def expire_stale(self, connection: psycopg.Connection) -> None:
        with connection.transaction():
            expired = connection.execute(
                """UPDATE approval_requests SET status = 'expired'
                   WHERE status IN ('pending', 'approved') AND expires_at <= now()
                   RETURNING id"""
            ).fetchall()
            if expired:
                connection.execute(
                    """UPDATE tool_executions
                       SET status = 'denied', error_code = 'approval_expired',
                           error_message = 'Validation expirée', finished_at = now()
                       WHERE approval_request_id = ANY(%s) AND status = 'pending_approval'""",
                    ([row["id"] for row in expired],),
                )

    def list_approvals(
        self, connection: psycopg.Connection, status: str | None, limit: int
    ) -> list[ApprovalView]:
        self.expire_stale(connection)
        rows = connection.execute(
            """SELECT * FROM approval_requests
               WHERE %(status)s::text IS NULL OR status = %(status)s
               ORDER BY created_at DESC LIMIT %(limit)s""",
            {"status": status, "limit": limit},
        ).fetchall()
        return [_approval(row) for row in rows]

    def get_approval(self, connection: psycopg.Connection, approval_id: UUID) -> ApprovalView:
        self.expire_stale(connection)
        row = connection.execute(
            "SELECT * FROM approval_requests WHERE id = %s", (approval_id,)
        ).fetchone()
        if row is None:
            raise ToolError(404, "approval_not_found", "Demande de validation introuvable")
        return _approval(row)

    def _locked(self, connection: psycopg.Connection, approval_id: UUID) -> dict[str, Any]:
        row = connection.execute(
            """SELECT *, expires_at <= now() AS is_expired
               FROM approval_requests WHERE id = %s FOR UPDATE""",
            (approval_id,),
        ).fetchone()
        if row is None:
            raise ToolError(404, "approval_not_found", "Demande de validation introuvable")
        return row

    def _mark_expired(self, connection: psycopg.Connection, approval_id: UUID) -> None:
        connection.execute(
            "UPDATE approval_requests SET status = 'expired' WHERE id = %s", (approval_id,)
        )
        connection.execute(
            """UPDATE tool_executions
               SET status = 'denied', error_code = 'approval_expired',
                   error_message = 'Validation expirée', finished_at = now()
               WHERE approval_request_id = %s AND status = 'pending_approval'""",
            (approval_id,),
        )

    def approve(
        self, connection: psycopg.Connection, approval_id: UUID, expected_hash: str
    ) -> ApprovalView:
        """Record the decision. The hash proves the approver saw these exact parameters."""
        expired = False
        with connection.transaction():
            row = self._locked(connection, approval_id)
            if row["arguments_hash"] != expected_hash:
                raise ToolError(
                    409,
                    "approval_arguments_mismatch",
                    "L’empreinte ne correspond pas aux paramètres présentés",
                )
            if row["status"] in ("pending", "approved") and row["is_expired"]:
                self._mark_expired(connection, approval_id)
                expired = True
            elif row["status"] == "pending":
                row = connection.execute(
                    """UPDATE approval_requests SET status = 'approved', decided_at = now()
                       WHERE id = %s RETURNING *""",
                    (approval_id,),
                ).fetchone()
                logger.info("approval_approved approval=%s", approval_id)
            elif row["status"] != "approved":
                raise ToolError(409, f"approval_{row['status']}", _status_message(row["status"]))
        if expired:
            # Raised after commit so the expiry is persisted.
            raise ToolError(410, "approval_expired", _status_message("expired"))
        return _approval(row)

    def reject(
        self, connection: psycopg.Connection, approval_id: UUID, reason: str | None
    ) -> ApprovalView:
        with connection.transaction():
            row = self._locked(connection, approval_id)
            if row["status"] == "rejected":
                return _approval(row)
            if row["status"] not in ("pending", "approved"):
                raise ToolError(409, f"approval_{row['status']}", _status_message(row["status"]))
            row = connection.execute(
                """UPDATE approval_requests
                   SET status = 'rejected', decided_at = now(), decision_reason = %s
                   WHERE id = %s RETURNING *""",
                (reason, approval_id),
            ).fetchone()
            connection.execute(
                """UPDATE tool_executions
                   SET status = 'denied', error_code = 'approval_rejected',
                       error_message = 'Action refusée par l’utilisateur', finished_at = now()
                   WHERE approval_request_id = %s AND status = 'pending_approval'""",
                (approval_id,),
            )
        logger.info("approval_rejected approval=%s", approval_id)
        return _approval(row)

    def execute_approved(
        self,
        connection: psycopg.Connection,
        principal: Principal,
        approval_id: UUID,
        raw_arguments: Any,
    ) -> ExecutionView:
        """Run an approved action once. Retries return the stored outcome."""
        expired = False
        with connection.transaction():
            # Row lock: concurrent calls are serialised; only the first one consumes it.
            row = self._locked(connection, approval_id)
            spec = self.registry.get(row["tool_name"])
            if spec is None:
                raise ToolError(404, "unknown_tool", "Outil inconnu ou non autorisé")
            params = self._validate(spec, raw_arguments)
            arguments = params.model_dump(mode="json")
            if arguments_hash(spec.name, arguments) != row["arguments_hash"]:
                raise ToolError(
                    409,
                    "approval_arguments_mismatch",
                    "Paramètres différents de ceux approuvés : une nouvelle validation est requise",
                )
            if row["status"] == "consumed":
                execution = connection.execute(
                    "SELECT * FROM tool_executions WHERE approval_request_id = %s "
                    "AND status <> 'pending_approval' ORDER BY created_at LIMIT 1",
                    (approval_id,),
                ).fetchone()
                view = _execution(execution, _approval(row))
                view.replayed = True
                return view
            if row["status"] in ("pending", "approved") and row["is_expired"]:
                self._mark_expired(connection, approval_id)
                expired = True
            elif row["status"] != "approved":
                raise ToolError(409, f"approval_{row['status']}", _status_message(row["status"]))
            else:
                try:
                    authorize(principal, spec)
                except PermissionDenied as denied:
                    raise ToolError(403, "permission_denied", str(denied)) from None
                approval_row = connection.execute(
                    """UPDATE approval_requests SET status = 'consumed', consumed_at = now()
                       WHERE id = %s AND status = 'approved' RETURNING *""",
                    (approval_id,),
                ).fetchone()
                execution = connection.execute(
                    """UPDATE tool_executions SET status = 'running', started_at = now()
                       WHERE approval_request_id = %s AND status = 'pending_approval'
                       RETURNING *""",
                    (approval_id,),
                ).fetchone()
                if execution is None:
                    execution = connection.execute(
                        """INSERT INTO tool_executions
                               (conversation_id, approval_request_id, tool_name, arguments,
                                arguments_hash, source, status, started_at)
                           VALUES (%s, %s, %s, %s, %s, 'api', 'running', now()) RETURNING *""",
                        (
                            row["conversation_id"],
                            approval_id,
                            spec.name,
                            Jsonb(arguments),
                            row["arguments_hash"],
                        ),
                    ).fetchone()
        if expired:
            raise ToolError(410, "approval_expired", _status_message("expired"))
        logger.info("approval_consumed approval=%s", approval_id)
        return self._run(connection, spec, params, execution["id"], _approval(approval_row))


def _status_message(status: str) -> str:
    return {
        "pending": "Action pas encore approuvée",
        "rejected": "Action refusée : une nouvelle demande est nécessaire",
        "expired": "Validation expirée : une nouvelle demande est nécessaire",
        "consumed": "Validation déjà utilisée",
    }.get(status, "Validation invalide")
