// Typed views of the backend responses documented in docs/API.md.
// Field names follow the JSON contract exactly; unknown fields are ignored.

DateTime _date(Object? value) => DateTime.parse(value as String);

DateTime? _optionalDate(Object? value) => value == null ? null : _date(value);

Map<String, dynamic> _map(Object? value) =>
    value == null ? const {} : Map<String, dynamic>.from(value as Map);

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: json['title'] as String,
    status: json['status'] as String,
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
  );

  final String id;
  final String title;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.toolExecutionId,
    this.approvalRequestId,
    this.provider,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    status: json['status'] as String,
    toolExecutionId: json['tool_execution_id'] as String?,
    approvalRequestId: json['approval_request_id'] as String?,
    provider: json['provider'] as String?,
    createdAt: _date(json['created_at']),
  );

  final String id;

  /// `user`, `assistant` or `tool`.
  final String role;
  final String content;

  /// `ok`, `error` or `pending_approval`.
  final String status;
  final String? toolExecutionId;
  final String? approvalRequestId;
  final String? provider;
  final DateTime createdAt;

  bool get isSimulated => provider == 'simulated';
}

class ConversationDetail {
  const ConversationDetail({
    required this.conversation,
    required this.messages,
  });

  factory ConversationDetail.fromJson(Map<String, dynamic> json) =>
      ConversationDetail(
        conversation: Conversation.fromJson(json),
        messages: [
          for (final item in json['messages'] as List)
            ChatMessage.fromJson(_map(item)),
        ],
      );

  final Conversation conversation;
  final List<ChatMessage> messages;
}

class Approval {
  const Approval({
    required this.id,
    required this.tool,
    required this.arguments,
    required this.argumentsHash,
    required this.summary,
    required this.risk,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
    this.conversationId,
    this.decidedAt,
    this.decisionReason,
    this.consumedAt,
  });

  factory Approval.fromJson(Map<String, dynamic> json) => Approval(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String?,
    tool: json['tool'] as String,
    arguments: _map(json['arguments']),
    argumentsHash: json['arguments_hash'] as String,
    summary: json['summary'] as String,
    risk: json['risk'] as String,
    status: json['status'] as String,
    expiresAt: _date(json['expires_at']),
    decidedAt: _optionalDate(json['decided_at']),
    decisionReason: json['decision_reason'] as String?,
    consumedAt: _optionalDate(json['consumed_at']),
    createdAt: _date(json['created_at']),
  );

  final String id;
  final String? conversationId;
  final String tool;

  /// Exact parameters as stored by the server; sent back unchanged on execution.
  final Map<String, dynamic> arguments;
  final String argumentsHash;
  final String summary;

  /// `low`, `medium` or `high`.
  final String risk;

  /// `pending`, `approved`, `rejected`, `expired` or `consumed`.
  final String status;
  final DateTime expiresAt;
  final DateTime? decidedAt;
  final String? decisionReason;
  final DateTime? consumedAt;
  final DateTime createdAt;
}

class ToolExecution {
  const ToolExecution({
    required this.executionId,
    required this.tool,
    required this.status,
    this.result,
    this.errorCode,
    this.errorMessage,
    this.approval,
    this.replayed = false,
  });

  factory ToolExecution.fromJson(Map<String, dynamic> json) => ToolExecution(
    executionId: json['execution_id'] as String,
    tool: json['tool'] as String,
    status: json['status'] as String,
    result: json['result'] == null ? null : _map(json['result']),
    errorCode: json['error_code'] as String?,
    errorMessage: json['error_message'] as String?,
    approval: json['approval'] == null
        ? null
        : Approval.fromJson(_map(json['approval'])),
    replayed: json['replayed'] as bool? ?? false,
  );

  final String executionId;
  final String tool;

  /// `denied`, `invalid`, `pending_approval`, `running`, `succeeded`, `failed`, `timed_out`.
  final String status;
  final Map<String, dynamic>? result;
  final String? errorCode;
  final String? errorMessage;
  final Approval? approval;

  /// True when the server returned the stored outcome without running the action again.
  final bool replayed;
}

class ProviderInfo {
  const ProviderInfo({
    required this.name,
    required this.model,
    required this.real,
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) => ProviderInfo(
    name: json['name'] as String,
    model: json['model'] as String,
    real: json['real'] as bool,
  );

  final String name;
  final String model;
  final bool real;
}

class TurnResult {
  const TurnResult({
    required this.conversationId,
    required this.status,
    required this.messages,
    required this.toolExecutions,
    required this.provider,
    this.errorCode,
  });

  factory TurnResult.fromJson(Map<String, dynamic> json) => TurnResult(
    conversationId: json['conversation_id'] as String,
    status: json['status'] as String,
    messages: [
      for (final item in json['messages'] as List)
        ChatMessage.fromJson(_map(item)),
    ],
    toolExecutions: [
      for (final item in json['tool_executions'] as List)
        ToolExecution.fromJson(_map(item)),
    ],
    provider: ProviderInfo.fromJson(_map(json['provider'])),
    errorCode: json['error_code'] as String?,
  );

  final String conversationId;

  /// `completed`, `pending_approval` or `limit_reached`.
  final String status;
  final List<ChatMessage> messages;
  final List<ToolExecution> toolExecutions;
  final ProviderInfo provider;
  final String? errorCode;
}

class AiStatus {
  const AiStatus({
    required this.configured,
    required this.detail,
    this.provider,
  });

  factory AiStatus.fromJson(Map<String, dynamic> json) => AiStatus(
    provider: json['provider'] == null
        ? null
        : ProviderInfo.fromJson(_map(json['provider'])),
    configured: json['configured'] as bool,
    detail: json['detail'] as String,
  );

  final ProviderInfo? provider;
  final bool configured;
  final String detail;
}

/// Recipient of an activity analysis, as the server describes it.
class AnalysisRecipient {
  const AnalysisRecipient({
    required this.configured,
    required this.label,
    this.provider,
    this.destination,
  });

  factory AnalysisRecipient.fromJson(Map<String, dynamic> json) =>
      AnalysisRecipient(
        provider: json['provider'] == null
            ? null
            : ProviderInfo.fromJson(_map(json['provider'])),
        configured: json['configured'] as bool,
        destination: json['destination'] as String?,
        label: json['label'] as String,
      );

  final ProviderInfo? provider;
  final bool configured;

  /// Host the server sends to, e.g. `integrate.api.nvidia.com`.
  final String? destination;
  final String label;

  /// Identity the confirmation is bound to.
  String get key =>
      '${provider?.name}|${provider?.model}|${provider?.real}|$destination';
}

class AnalysisResult {
  const AnalysisResult({required this.text, required this.simulated});

  factory AnalysisResult.fromJson(Map<String, dynamic> json) => AnalysisResult(
    text: json['text'] as String,
    simulated: json['simulated'] as bool,
  );

  final String text;
  final bool simulated;
}

class Capacity {
  const Capacity({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.usedPercent,
  });

  factory Capacity.fromJson(Map<String, dynamic> json) => Capacity(
    totalBytes: json['total_bytes'] as int,
    usedBytes: json['used_bytes'] as int,
    availableBytes: json['available_bytes'] as int,
    usedPercent: (json['used_percent'] as num).toDouble(),
  );

  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double usedPercent;
}

class ServerMetrics {
  const ServerMetrics({
    required this.observedAt,
    required this.scope,
    required this.cpuPercent,
    required this.memory,
    required this.disk,
  });

  factory ServerMetrics.fromJson(Map<String, dynamic> json) => ServerMetrics(
    observedAt: _date(json['observed_at']),
    scope: json['scope'] as String,
    cpuPercent: (json['cpu_percent'] as num).toDouble(),
    memory: Capacity.fromJson(_map(json['memory'])),
    disk: Capacity.fromJson(_map(json['disk'])),
  );

  final DateTime observedAt;

  /// `host` (Ubuntu server) or `runtime` (container environment).
  final String scope;
  final double cpuPercent;
  final Capacity memory;
  final Capacity disk;
}

double? _optionalDouble(Object? value) =>
    value == null ? null : (value as num).toDouble();

/// Allowed check intervals, in minutes (same list as the backend).
const automationIntervals = [15, 30, 60, 120, 180, 360, 720, 1440];

class AutomationRun {
  const AutomationRun({
    required this.id,
    required this.automationId,
    required this.trigger,
    required this.scheduledFor,
    required this.missedSlots,
    required this.startedAt,
    required this.finishedAt,
    required this.status,
    required this.measuredPercent,
    required this.thresholdPercent,
    required this.errorCode,
    required this.message,
    required this.notified,
  });

  factory AutomationRun.fromJson(Map<String, dynamic> json) => AutomationRun(
    id: json['id'] as String,
    automationId: json['automation_id'] as String,
    trigger: json['trigger'] as String,
    scheduledFor: _optionalDate(json['scheduled_for']),
    missedSlots: json['missed_slots'] as int,
    startedAt: _date(json['started_at']),
    finishedAt: _date(json['finished_at']),
    status: json['status'] as String,
    measuredPercent: _optionalDouble(json['measured_percent']),
    thresholdPercent: (json['threshold_percent'] as num).toDouble(),
    errorCode: json['error_code'] as String?,
    message: json['message'] as String,
    notified: json['notified'] as bool,
  );

  final String id;
  final String automationId;

  /// `schedule` or `manual`.
  final String trigger;
  final DateTime? scheduledFor;
  final int missedSlots;
  final DateTime startedAt;
  final DateTime finishedAt;

  /// `ok`, `alert` or `failed`.
  final String status;
  final double? measuredPercent;
  final double thresholdPercent;
  final String? errorCode;
  final String message;
  final bool notified;
}

class Automation {
  const Automation({
    required this.id,
    required this.name,
    required this.kind,
    required this.thresholdPercent,
    required this.intervalMinutes,
    required this.timezone,
    required this.enabled,
    required this.nextRunAt,
    required this.alertActive,
    required this.failing,
    required this.lastRun,
    required this.updatedAt,
  });

  factory Automation.fromJson(Map<String, dynamic> json) => Automation(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String,
    thresholdPercent: (json['threshold_percent'] as num).toDouble(),
    intervalMinutes: json['interval_minutes'] as int,
    timezone: json['timezone'] as String,
    enabled: json['enabled'] as bool,
    nextRunAt: _optionalDate(json['next_run_at']),
    alertActive: json['alert_active'] as bool,
    failing: json['failing'] as bool,
    lastRun: json['last_run'] == null
        ? null
        : AutomationRun.fromJson(_map(json['last_run'])),
    updatedAt: _date(json['updated_at']),
  );

  final String id;
  final String name;
  final String kind;
  final double thresholdPercent;
  final int intervalMinutes;

  /// IANA time zone of the schedule, e.g. `Europe/Paris`.
  final String timezone;
  final bool enabled;

  /// Null while suspended.
  final DateTime? nextRunAt;
  final bool alertActive;
  final bool failing;
  final AutomationRun? lastRun;
  final DateTime updatedAt;
}

class ServerNotification {
  const ServerNotification({
    required this.id,
    required this.createdAt,
    required this.level,
    required this.title,
    required this.body,
  });

  factory ServerNotification.fromJson(Map<String, dynamic> json) =>
      ServerNotification(
        id: json['id'] as int,
        createdAt: _date(json['created_at']),
        level: json['level'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
      );

  final int id;
  final DateTime createdAt;

  /// `alert`, `recovery` or `failure`.
  final String level;
  final String title;
  final String body;
}

class NotificationPage {
  const NotificationPage({required this.items, required this.latestId});

  factory NotificationPage.fromJson(Map<String, dynamic> json) =>
      NotificationPage(
        items: [
          for (final item in json['items'] as List)
            ServerNotification.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        latestId: json['latest_id'] as int,
      );

  final List<ServerNotification> items;
  final int latestId;
}

class GitHubCommit {
  const GitHubCommit({required this.sha, required this.message, this.date});

  factory GitHubCommit.fromJson(Map<String, dynamic> json) => GitHubCommit(
    sha: json['sha'] as String,
    message: json['message'] as String,
    date: _optionalDate(json['date']),
  );

  final String sha;
  final String message;
  final DateTime? date;
}

class GitHubRun {
  const GitHubRun({
    required this.name,
    required this.status,
    required this.conclusion,
    required this.createdAt,
  });

  factory GitHubRun.fromJson(Map<String, dynamic> json) => GitHubRun(
    name: json['name'] as String?,
    status: json['status'] as String?,
    conclusion: json['conclusion'] as String?,
    createdAt: _date(json['created_at']),
  );

  final String? name;
  final String? status;

  /// `success`, `failure`, `cancelled`… ; null while running.
  final String? conclusion;
  final DateTime createdAt;
}

class GitHubRepo {
  const GitHubRepo({
    required this.repo,
    required this.available,
    required this.error,
    required this.openIssues,
    required this.commits,
    required this.runs,
  });

  factory GitHubRepo.fromJson(Map<String, dynamic> json) => GitHubRepo(
    repo: json['repo'] as String,
    available: json['available'] as bool,
    error: json['error'] as String?,
    openIssues: json['open_issues'] as int?,
    commits: [
      for (final item in json['commits'] as List)
        GitHubCommit.fromJson(_map(item)),
    ],
    runs: [
      for (final item in json['workflow_runs'] as List)
        GitHubRun.fromJson(_map(item)),
    ],
  );

  final String repo;
  final bool available;
  final String? error;
  final int? openIssues;
  final List<GitHubCommit> commits;
  final List<GitHubRun> runs;
}

class GitHubReport {
  const GitHubReport({required this.configured, required this.repos});

  factory GitHubReport.fromJson(Map<String, dynamic> json) => GitHubReport(
    configured: json['configured'] as bool,
    repos: [
      for (final item in json['repos'] as List) GitHubRepo.fromJson(_map(item)),
    ],
  );

  final bool configured;
  final List<GitHubRepo> repos;
}
