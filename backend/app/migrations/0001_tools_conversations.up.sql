-- Conversations, messages, tool executions and persistent approvals.
CREATE TABLE conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 200),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE approval_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid REFERENCES conversations (id) ON DELETE SET NULL,
    tool_name text NOT NULL,
    arguments jsonb NOT NULL,
    arguments_hash text NOT NULL CHECK (char_length(arguments_hash) = 64),
    summary text NOT NULL,
    risk_level text NOT NULL CHECK (risk_level IN ('low', 'medium', 'high')),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'expired', 'consumed')),
    expires_at timestamptz NOT NULL,
    decided_at timestamptz,
    decision_reason text CHECK (char_length(decision_reason) <= 500),
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX approval_requests_status_idx ON approval_requests (status, created_at DESC);

CREATE TABLE tool_executions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid REFERENCES conversations (id) ON DELETE SET NULL,
    approval_request_id uuid REFERENCES approval_requests (id) ON DELETE RESTRICT,
    tool_name text NOT NULL,
    arguments jsonb,
    arguments_hash text,
    source text NOT NULL CHECK (source IN ('api', 'assistant')),
    status text NOT NULL CHECK (
        status IN ('denied', 'invalid', 'pending_approval', 'running', 'succeeded', 'failed', 'timed_out')
    ),
    result jsonb,
    error_code text,
    error_message text,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz
);
CREATE INDEX tool_executions_conversation_idx ON tool_executions (conversation_id, created_at);
-- At most one execution may run for an approval: the database refuses a second one.
CREATE UNIQUE INDEX tool_executions_one_run_per_approval
    ON tool_executions (approval_request_id)
    WHERE status IN ('running', 'succeeded', 'failed', 'timed_out');

CREATE TABLE messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('user', 'assistant', 'tool')),
    content text NOT NULL CHECK (char_length(content) <= 20000),
    status text NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'error', 'pending_approval')),
    tool_execution_id uuid REFERENCES tool_executions (id) ON DELETE SET NULL,
    approval_request_id uuid REFERENCES approval_requests (id) ON DELETE SET NULL,
    provider text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX messages_conversation_idx ON messages (conversation_id, created_at);
