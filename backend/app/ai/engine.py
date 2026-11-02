import json
import logging
import time
import zlib
from typing import Any, Literal
from uuid import UUID

import psycopg
from pydantic import BaseModel

from app import conversations
from app.ai.base import AIProvider, ProviderError
from app.config import Settings
from app.conversations import MessageView
from app.tools.permissions import Principal
from app.tools.service import ExecutionView, ToolService

logger = logging.getLogger("nexora.ai")

SYSTEM_PROMPT = (
    "Tu es NEXORA, l’assistant personnel de l’utilisateur. Réponds en français, "
    "clairement et brièvement. Pour obtenir une information sur le serveur, utilise "
    "uniquement les outils fournis ; n’invente jamais un résultat. Tu n’as aucun autre "
    "accès au système. Si un outil renvoie un refus ou une erreur, explique-le simplement. "
    "Une action soumise à validation n’est pas exécutée tant que l’utilisateur ne l’a pas "
    "approuvée : ne prétends jamais qu’elle a eu lieu."
)
SIMULATION_NOTICE = "[Mode simulé — aucune IA réelle] "
MAX_TOOL_CONTENT = 8000
MAX_ACTION_RESULT = 1000
MAX_ACTIONS_CONTEXT = 6000
RECENT_ACTIONS = 10
ACTIONS_HEADER = (
    "État actuel des actions de cette conversation, fourni par le serveur NEXORA. Il fait "
    "foi sur les messages précédents, y compris les anciens avis « Validation requise ». "
    "Statuts : execution=succeeded → exécutée avec ce résultat ; pending_approval → en "
    "attente, non exécutée ; approval=rejected → refusée par l’utilisateur, non exécutée ; "
    "approval=expired → expirée, non exécutée ; failed ou timed_out → échec. Ne relance "
    "jamais une action déjà exécutée sauf demande explicite de l’utilisateur, qui devra "
    "alors la valider de nouveau. Actions, de la plus récente à la plus ancienne :"
)


class ProviderInfo(BaseModel):
    name: str
    model: str
    real: bool


class TurnResult(BaseModel):
    conversation_id: UUID
    status: Literal["completed", "pending_approval", "limit_reached", "provider_error"]
    messages: list[MessageView]
    tool_executions: list[ExecutionView]
    provider: ProviderInfo
    error_code: str | None = None


def turn_lock_key(conversation_id: UUID) -> int:
    # Session advisory lock: one turn at a time per conversation.
    return (0x4E58 << 32) | zlib.crc32(conversation_id.bytes)


class TurnBusy(Exception):
    """Another turn is already running for this conversation."""


def tool_content(execution: ExecutionView) -> str:
    payload: dict[str, Any] = {"tool": execution.tool, "status": execution.status}
    if execution.result is not None:
        payload["result"] = execution.result
    if execution.error_code:
        payload["error"] = {"code": execution.error_code, "message": execution.error_message}
    if execution.approval:
        payload["approval"] = {
            "id": str(execution.approval.id),
            "summary": execution.approval.summary,
            "expires_at": execution.approval.expires_at.isoformat(),
            "note": "Action non exécutée : en attente de validation par l’utilisateur.",
        }
    text = json.dumps(payload, ensure_ascii=False, default=str)
    return text if len(text) <= MAX_TOOL_CONTENT else text[:MAX_TOOL_CONTENT] + "…"


def _approval_text(executions: list[ExecutionView]) -> str:
    lines = ["Validation requise avant toute exécution :"]
    for execution in executions:
        approval = execution.approval
        lines.append(
            f"- {approval.summary} — demande {approval.id}, "
            f"expire le {approval.expires_at:%d/%m/%Y à %H:%M} UTC."
        )
    lines.append("Approuvez ou refusez via /api/v1/approvals/{id}.")
    return "\n".join(lines)


class AssistantEngine:
    def __init__(self, settings: Settings, tools: ToolService, provider: AIProvider) -> None:
        self.settings = settings
        self.tools = tools
        self.provider = provider
        self.info = ProviderInfo(name=provider.name, model=provider.model, real=provider.real)

    def _recent_actions(
        self, connection: psycopg.Connection, conversation_id: UUID
    ) -> tuple[str, dict[UUID, str]]:
        """Summarise persisted executions and approvals; returns text and approval statuses.

        Past tool messages cannot be replayed as protocol ``tool`` messages: their call ids
        belong to earlier requests. The current state is therefore given as system context.
        """
        self.tools.expire_stale(connection)
        rows = connection.execute(
            """SELECT e.tool_name, e.arguments, e.status, e.result, e.error_code,
                      e.created_at, a.id AS approval_id, a.status AS approval_status
               FROM tool_executions e
               LEFT JOIN approval_requests a ON a.id = e.approval_request_id
               WHERE e.conversation_id = %s
               ORDER BY e.created_at DESC LIMIT %s""",
            (conversation_id, RECENT_ACTIONS),
        ).fetchall()
        statuses = {
            row["approval_id"]: row["approval_status"] for row in rows if row["approval_id"]
        }
        lines = []
        for row in rows:
            item: dict[str, Any] = {
                "tool": row["tool_name"],
                "arguments": row["arguments"],
                "execution": row["status"],
                "at": row["created_at"].isoformat(timespec="seconds"),
            }
            if row["approval_id"]:
                item["approval"] = row["approval_status"]
                item["approval_id"] = str(row["approval_id"])
            if row["error_code"]:
                item["error"] = row["error_code"]
            if row["result"] is not None:
                result = json.dumps(row["result"], ensure_ascii=False, default=str)
                item["result"] = (
                    row["result"]
                    if len(result) <= MAX_ACTION_RESULT
                    else result[:MAX_ACTION_RESULT] + "…"
                )
            lines.append("- " + json.dumps(item, ensure_ascii=False, default=str))
        text = ""
        for line in lines:
            if len(text) + len(line) > MAX_ACTIONS_CONTEXT:
                break
            text += line + "\n"
        return (ACTIONS_HEADER + "\n" + text.rstrip()) if text else "", statuses

    def _history(
        self, connection: psycopg.Connection, conversation_id: UUID, statuses: dict[UUID, str]
    ) -> list[dict]:
        history = []
        recent = conversations.messages(
            connection, conversation_id, self.settings.nexora_ai_history_messages
        )
        for message in recent:
            # Tool traces stay out of later turns: their tool_call ids belong to past calls.
            if message.role in ("user", "assistant") and message.status == "ok":
                content = message.content
                current = statuses.get(message.approval_request_id)
                if current and current != "pending":
                    content += f"\n[Mise à jour du serveur : demande désormais « {current} ».]"
                history.append({"role": message.role, "content": content})
        return history

    def _say(self, connection, conversation_id, text, **extra) -> MessageView:
        if not self.provider.real:
            text = SIMULATION_NOTICE + text
        return conversations.add_message(
            connection, conversation_id, "assistant", text, provider=self.provider.name, **extra
        )

    def run_turn(
        self,
        connection: psycopg.Connection,
        principal: Principal,
        conversation_id: UUID,
        text: str,
    ) -> TurnResult:
        lock_key = turn_lock_key(conversation_id)
        locked = connection.execute(
            "SELECT pg_try_advisory_lock(%s) AS ok", (lock_key,)
        ).fetchone()["ok"]
        if not locked:
            raise TurnBusy()
        try:
            return self._turn(connection, principal, conversation_id, text)
        finally:
            connection.execute("SELECT pg_advisory_unlock(%s)", (lock_key,))

    def _turn(self, connection, principal, conversation_id, text) -> TurnResult:
        settings = self.settings
        created = [conversations.add_message(connection, conversation_id, "user", text)]
        executions: list[ExecutionView] = []
        actions, statuses = self._recent_actions(connection, conversation_id)
        system = SYSTEM_PROMPT + ("\n\n" + actions if actions else "")
        messages = [{"role": "system", "content": system}]
        messages += self._history(connection, conversation_id, statuses)
        exposed = [
            spec.function_schema() for spec in self.tools.registry.allowed(principal.permissions)
        ]
        deadline = time.monotonic() + settings.nexora_ai_turn_deadline_seconds
        calls = 0

        def finish(turn_status, reply, error_code=None, **extra) -> TurnResult:
            created.append(self._say(connection, conversation_id, reply, **extra))
            logger.info("turn_finished status=%s tool_calls=%d", turn_status, calls)
            return TurnResult(
                conversation_id=conversation_id,
                status=turn_status,
                messages=created,
                tool_executions=executions,
                provider=self.info,
                error_code=error_code,
            )

        for _ in range(settings.nexora_ai_max_iterations):
            remaining = deadline - time.monotonic()
            if remaining < 1:
                return finish(
                    "limit_reached", "Durée maximale de traitement atteinte pour cette demande."
                )
            try:
                reply = self.provider.complete(
                    messages, exposed, min(settings.nexora_ai_timeout_seconds, remaining)
                )
            except ProviderError as error:
                logger.warning("provider_error code=%s", error.code)
                return finish(
                    "provider_error",
                    f"Le fournisseur IA est indisponible ({error.message}). "
                    "Les contrôles du serveur restent accessibles directement.",
                    error_code=error.code,
                    status="error",
                )
            if not reply.tool_calls:
                return finish("completed", reply.text.strip() or "(réponse vide du modèle)")

            messages.append(
                {
                    "role": "assistant",
                    "content": reply.text or None,
                    "tool_calls": [
                        {
                            "id": call.id,
                            "type": "function",
                            "function": {"name": call.name, "arguments": call.arguments},
                        }
                        for call in reply.tool_calls
                    ],
                }
            )
            pending: list[ExecutionView] = []
            limit_hit = deadline_hit = False
            for call in reply.tool_calls:
                # Re-check the global budget before each tool: never start one after it.
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    deadline_hit = True
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": '{"error":"turn_deadline"}',
                        }
                    )
                    continue
                if calls >= settings.nexora_ai_max_tool_calls:
                    limit_hit = True
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": '{"error":"tool_call_limit"}',
                        }
                    )
                    continue
                calls += 1
                try:
                    arguments = json.loads(call.arguments)
                except ValueError:
                    arguments = "invalid-json"  # Rejected by validation, never executed.
                execution = self.tools.request(
                    connection,
                    principal,
                    call.name,
                    arguments,
                    source="assistant",
                    conversation_id=conversation_id,
                    max_seconds=remaining,
                )
                executions.append(execution)
                content = tool_content(execution)
                created.append(
                    conversations.add_message(
                        connection,
                        conversation_id,
                        "tool",
                        content,
                        status="pending_approval"
                        if execution.approval
                        else ("ok" if execution.status == "succeeded" else "error"),
                        tool_execution_id=execution.execution_id,
                        approval_request_id=execution.approval.id if execution.approval else None,
                    )
                )
                messages.append({"role": "tool", "tool_call_id": call.id, "content": content})
                if execution.status == "pending_approval":
                    pending.append(execution)

            if pending:
                prefix = (reply.text.strip() + "\n\n") if reply.text.strip() else ""
                return finish(
                    "pending_approval",
                    prefix + _approval_text(pending),
                    approval_request_id=pending[0].approval.id,
                )
            if deadline_hit:
                return finish(
                    "limit_reached",
                    "Durée maximale de traitement atteinte : les outils restants n’ont pas été "
                    "lancés.",
                )
            if limit_hit:
                return finish(
                    "limit_reached",
                    f"Limite de {settings.nexora_ai_max_tool_calls} appels d’outils atteinte "
                    "pour cette demande. Reformulez ou découpez la demande.",
                )
        return finish(
            "limit_reached", "Nombre maximal d’échanges avec le modèle atteint pour cette demande."
        )
