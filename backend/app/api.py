import logging
from collections.abc import Iterator
from typing import Annotated, Any, Literal
from uuid import UUID

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from app import automations, conversations
from app.ai.engine import AssistantEngine, ProviderInfo, TurnBusy, TurnResult, tool_content
from app.automations import (
    AutomationChanges,
    AutomationError,
    AutomationView,
    NewAutomation,
    NotificationPage,
    RunView,
)
from app.conversations import ConversationView, MessageView
from app.database import connect
from app.github import GitHubReport
from app.security import get_principal, require_permission
from app.tools.permissions import Principal
from app.tools.service import ApprovalView, ExecutionView, ToolError, ToolService

logger = logging.getLogger("nexora")
router = APIRouter(prefix="/api/v1")
Caller = Annotated[Principal, Depends(get_principal)]
HASH = r"^[0-9a-f]{64}$"


def get_connection(request: Request) -> Iterator[psycopg.Connection]:
    with connect(request.app.state.settings) as connection:
        yield connection


Db = Annotated[psycopg.Connection, Depends(get_connection)]


def tool_service(request: Request) -> ToolService:
    return request.app.state.tools


Tools = Annotated[ToolService, Depends(tool_service)]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class InvokeRequest(Strict):
    arguments: dict[str, Any] = Field(default_factory=dict)


class ApproveRequest(Strict):
    arguments_hash: str = Field(pattern=HASH)


class RejectRequest(Strict):
    reason: str | None = Field(default=None, max_length=500)


class ExecuteRequest(Strict):
    arguments: dict[str, Any] = Field(default_factory=dict)


class NewConversation(Strict):
    title: str = Field(default="Nouvelle conversation", min_length=1, max_length=200)


class ConversationDetail(ConversationView):
    messages: list[MessageView]


class AIStatus(BaseModel):
    provider: ProviderInfo | None
    configured: bool
    detail: str


def _raise(error: ToolError) -> None:
    raise HTTPException(error.status_code, {"code": error.code, "message": error.message})


def _refusal(execution: ExecutionView) -> None:
    codes = {"unknown_tool": 404, "permission_denied": 403, "invalid_arguments": 422}
    if execution.status in ("denied", "invalid"):
        raise HTTPException(
            codes.get(execution.error_code, 403),
            {
                "code": execution.error_code,
                "message": execution.error_message,
                "execution_id": str(execution.execution_id),
            },
        )


# ----- Tools ------------------------------------------------------------------


@router.get("/tools", tags=["tools"])
def list_tools(caller: Caller, tools: Tools) -> list[dict[str, Any]]:
    return [
        spec.public() | {"allowed": spec.permissions <= caller.permissions}
        for spec in tools.registry.all()
    ]


@router.post("/tools/{name}/invoke", response_model=ExecutionView, tags=["tools"])
def invoke_tool(name: str, body: InvokeRequest, caller: Caller, tools: Tools, db: Db):
    execution = tools.request(db, caller, name, body.arguments, source="api")
    _refusal(execution)
    if execution.status == "pending_approval":
        return JSONResponse(execution.model_dump(mode="json"), status_code=202)
    return execution


# ----- Approvals --------------------------------------------------------------


@router.get("/approvals", response_model=list[ApprovalView], tags=["approvals"])
def list_approvals(
    _: Caller,
    tools: Tools,
    db: Db,
    status_filter: Annotated[
        Literal["pending", "approved", "rejected", "expired", "consumed"] | None,
        Query(alias="status"),
    ] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
):
    return tools.list_approvals(db, status_filter, limit)


@router.get("/approvals/{approval_id}", response_model=ApprovalView, tags=["approvals"])
def get_approval(approval_id: UUID, _: Caller, tools: Tools, db: Db):
    try:
        return tools.get_approval(db, approval_id)
    except ToolError as error:
        _raise(error)


@router.post("/approvals/{approval_id}/approve", response_model=ApprovalView, tags=["approvals"])
def approve(approval_id: UUID, body: ApproveRequest, _: Caller, tools: Tools, db: Db):
    try:
        return tools.approve(db, approval_id, body.arguments_hash)
    except ToolError as error:
        _raise(error)


@router.post("/approvals/{approval_id}/reject", response_model=ApprovalView, tags=["approvals"])
def reject(approval_id: UUID, body: RejectRequest, _: Caller, tools: Tools, db: Db):
    try:
        return tools.reject(db, approval_id, body.reason)
    except ToolError as error:
        _raise(error)


@router.post("/approvals/{approval_id}/execute", response_model=ExecutionView, tags=["approvals"])
def execute(approval_id: UUID, body: ExecuteRequest, caller: Caller, tools: Tools, db: Db):
    try:
        execution = tools.execute_approved(db, caller, approval_id, body.arguments)
    except ToolError as error:
        _raise(error)
    conversation_id = execution.approval.conversation_id if execution.approval else None
    if conversation_id and not execution.replayed:
        conversations.add_message(
            db,
            conversation_id,
            "tool",
            tool_content(execution),
            status="ok" if execution.status == "succeeded" else "error",
            tool_execution_id=execution.execution_id,
            approval_request_id=execution.approval.id,
        )
    return execution


# ----- Conversations ----------------------------------------------------------


def _conversation_or_404(db: psycopg.Connection, conversation_id: UUID) -> ConversationView:
    conversation = conversations.get(db, conversation_id)
    if conversation is None:
        raise HTTPException(
            404, {"code": "conversation_not_found", "message": "Conversation introuvable"}
        )
    return conversation


@router.post(
    "/conversations",
    response_model=ConversationView,
    status_code=status.HTTP_201_CREATED,
    tags=["conversations"],
)
def create_conversation(body: NewConversation, _: Caller, db: Db):
    return conversations.create(db, body.title)


@router.get("/conversations", response_model=list[ConversationView], tags=["conversations"])
def list_conversations(_: Caller, db: Db, limit: Annotated[int, Query(ge=1, le=100)] = 20):
    return conversations.list_recent(db, limit)


@router.get(
    "/conversations/{conversation_id}", response_model=ConversationDetail, tags=["conversations"]
)
def conversation_history(
    conversation_id: UUID, _: Caller, db: Db, limit: Annotated[int, Query(ge=1, le=500)] = 100
):
    conversation = _conversation_or_404(db, conversation_id)
    return ConversationDetail(
        **conversation.model_dump(), messages=conversations.messages(db, conversation_id, limit)
    )


class UserMessage(Strict):
    content: str = Field(min_length=1)


@router.post(
    "/conversations/{conversation_id}/messages",
    response_model=TurnResult,
    tags=["conversations"],
)
def send_message(
    conversation_id: UUID, body: UserMessage, caller: Caller, request: Request, db: Db
):
    settings = request.app.state.settings
    text = body.content.strip()
    if not text or len(text) > settings.nexora_ai_max_input_chars:
        raise HTTPException(
            422,
            {
                "code": "invalid_message",
                "message": f"Message vide ou supérieur à {settings.nexora_ai_max_input_chars} "
                "caractères",
            },
        )
    engine: AssistantEngine | None = request.app.state.engine
    if engine is None or not engine.provider.configured():
        raise HTTPException(
            503, {"code": "ai_not_configured", "message": "Fournisseur IA non configuré"}
        )
    _conversation_or_404(db, conversation_id)
    try:
        result = engine.run_turn(db, caller, conversation_id, text)
    except TurnBusy:
        raise HTTPException(
            409, {"code": "turn_in_progress", "message": "Une demande est déjà en cours"}
        ) from None
    if result.status == "provider_error":
        raise HTTPException(
            503,
            {
                "code": f"ai_{result.error_code}",
                "message": result.messages[-1].content,
                "messages": [m.model_dump(mode="json") for m in result.messages],
            },
        )
    return result


@router.get("/ai/status", response_model=AIStatus, tags=["ai"])
def ai_status(_: Caller, request: Request):
    # Reports configuration only; never contacts the provider nor reveals the key.
    engine: AssistantEngine | None = request.app.state.engine
    if engine is None:
        return AIStatus(provider=None, configured=False, detail="Aucun fournisseur sélectionné")
    configured = engine.provider.configured()
    if not engine.provider.real:
        detail = "Fournisseur simulé : aucune connexion à une IA réelle"
    elif configured:
        detail = "Fournisseur configuré (clé présente, non vérifiée)"
    else:
        detail = "Fournisseur sélectionné mais clé absente"
    return AIStatus(provider=engine.info, configured=configured, detail=detail)


# ----- Automations ------------------------------------------------------------


def _automation_error(error: AutomationError) -> HTTPException:
    return HTTPException(error.status_code, {"code": error.code, "message": error.message})


Read = [Depends(require_permission("automation:read"))]
# Creating or running a disk check reads server data: it needs server:read too.
Write = [Depends(require_permission("automation:write"))]
Measure = [*Write, Depends(require_permission("server:read"))]


@router.get(
    "/automations", response_model=list[AutomationView], dependencies=Read, tags=["automations"]
)
def list_automations(db: Db):
    return automations.list_all(db)


@router.post(
    "/automations",
    response_model=AutomationView,
    status_code=status.HTTP_201_CREATED,
    dependencies=Measure,
    tags=["automations"],
)
def create_automation(body: NewAutomation, db: Db):
    try:
        return automations.create(db, body, automations.utc_now())
    except AutomationError as error:
        raise _automation_error(error) from None


@router.get(
    "/automations/{automation_id}",
    response_model=AutomationView,
    dependencies=Read,
    tags=["automations"],
)
def get_automation(automation_id: UUID, db: Db):
    try:
        return automations.get(db, automation_id)
    except AutomationError as error:
        raise _automation_error(error) from None


@router.patch(
    "/automations/{automation_id}",
    response_model=AutomationView,
    dependencies=Write,
    tags=["automations"],
)
def update_automation(automation_id: UUID, body: AutomationChanges, db: Db):
    try:
        return automations.update(db, automation_id, body, automations.utc_now())
    except AutomationError as error:
        raise _automation_error(error) from None


@router.delete(
    "/automations/{automation_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=Write,
    tags=["automations"],
)
def delete_automation(automation_id: UUID, db: Db) -> None:
    try:
        automations.delete(db, automation_id)
    except AutomationError as error:
        raise _automation_error(error) from None


@router.post(
    "/automations/{automation_id}/run",
    response_model=RunView,
    dependencies=Measure,
    tags=["automations"],
)
def run_automation(automation_id: UUID, request: Request, db: Db):
    try:
        return automations.run_now(
            db, automation_id, request.app.state.settings, request.app.state.measure
        )
    except AutomationError as error:
        raise _automation_error(error) from None


@router.get(
    "/automations/{automation_id}/runs",
    response_model=list[RunView],
    dependencies=Read,
    tags=["automations"],
)
def automation_runs(automation_id: UUID, db: Db, limit: Annotated[int, Query(ge=1, le=200)] = 50):
    try:
        return automations.runs(db, automation_id, limit)
    except AutomationError as error:
        raise _automation_error(error) from None


@router.get(
    "/notifications",
    response_model=NotificationPage,
    dependencies=[Depends(require_permission("notifications:read"))],
    tags=["notifications"],
)
def list_notifications(
    db: Db,
    after_id: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
):
    return automations.notifications(db, after_id, limit)


# ----- GitHub (read only) -----------------------------------------------------


@router.get(
    "/github",
    response_model=GitHubReport,
    dependencies=[Depends(require_permission("github:read"))],
    tags=["github"],
)
def github_report(request: Request):
    # Allow-listed repositories only; no repository name is taken from the request.
    return request.app.state.github.report()
