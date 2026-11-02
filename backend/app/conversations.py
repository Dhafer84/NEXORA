from datetime import datetime
from typing import Any, Literal
from uuid import UUID

import psycopg
from pydantic import BaseModel

MAX_STORED_CHARS = 20000


class MessageView(BaseModel):
    id: UUID
    role: Literal["user", "assistant", "tool"]
    content: str
    status: Literal["ok", "error", "pending_approval"]
    tool_execution_id: UUID | None
    approval_request_id: UUID | None
    provider: str | None
    created_at: datetime


class ConversationView(BaseModel):
    id: UUID
    title: str
    status: str
    created_at: datetime
    updated_at: datetime


def _conversation(row: dict[str, Any]) -> ConversationView:
    return ConversationView(**{key: row[key] for key in ConversationView.model_fields})


def _message(row: dict[str, Any]) -> MessageView:
    return MessageView(**{key: row[key] for key in MessageView.model_fields})


def create(connection: psycopg.Connection, title: str) -> ConversationView:
    row = connection.execute(
        "INSERT INTO conversations (title) VALUES (%s) RETURNING *", (title,)
    ).fetchone()
    return _conversation(row)


def get(connection: psycopg.Connection, conversation_id: UUID) -> ConversationView | None:
    row = connection.execute(
        "SELECT * FROM conversations WHERE id = %s", (conversation_id,)
    ).fetchone()
    return _conversation(row) if row else None


def list_recent(connection: psycopg.Connection, limit: int) -> list[ConversationView]:
    rows = connection.execute(
        "SELECT * FROM conversations ORDER BY updated_at DESC LIMIT %s", (limit,)
    ).fetchall()
    return [_conversation(row) for row in rows]


def add_message(
    connection: psycopg.Connection,
    conversation_id: UUID,
    role: str,
    content: str,
    *,
    status: str = "ok",
    tool_execution_id: UUID | None = None,
    approval_request_id: UUID | None = None,
    provider: str | None = None,
) -> MessageView:
    if len(content) > MAX_STORED_CHARS:
        content = content[: MAX_STORED_CHARS - 1] + "…"
    with connection.transaction():
        row = connection.execute(
            """INSERT INTO messages
                   (conversation_id, role, content, status, tool_execution_id,
                    approval_request_id, provider)
               VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *""",
            (
                conversation_id,
                role,
                content,
                status,
                tool_execution_id,
                approval_request_id,
                provider,
            ),
        ).fetchone()
        connection.execute(
            "UPDATE conversations SET updated_at = now() WHERE id = %s", (conversation_id,)
        )
    return _message(row)


def messages(
    connection: psycopg.Connection, conversation_id: UUID, limit: int
) -> list[MessageView]:
    rows = connection.execute(
        """SELECT * FROM (
               SELECT * FROM messages WHERE conversation_id = %s
               ORDER BY created_at DESC LIMIT %s
           ) recent ORDER BY created_at""",
        (conversation_id, limit),
    ).fetchall()
    return [_message(row) for row in rows]
