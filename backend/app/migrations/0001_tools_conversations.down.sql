-- Rollback of 0001: removes every conversation, execution and approval. Back up first.
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS tool_executions;
DROP TABLE IF EXISTS approval_requests;
DROP TABLE IF EXISTS conversations;
