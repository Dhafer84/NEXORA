import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/states.dart';

/// Structured content of a `tool` message, as written by the backend
/// (`{"tool", "status", "result"?, "error"?, "approval"?}`).
class ToolPayload {
  const ToolPayload({
    required this.tool,
    required this.status,
    this.result,
    this.error,
    this.approval,
  });

  /// Null when the message holds no structured data (older or truncated).
  static ToolPayload? tryParse(ChatMessage message) {
    try {
      final json = Map<String, dynamic>.from(
        jsonDecode(message.content) as Map,
      );
      return ToolPayload(
        tool: json['tool'] as String,
        status: json['status'] as String? ?? message.status,
        result: json['result'] is Map
            ? Map<String, dynamic>.from(json['result'] as Map)
            : null,
        error: json['error'] is Map
            ? Map<String, dynamic>.from(json['error'] as Map)
            : null,
        approval: json['approval'] is Map
            ? Map<String, dynamic>.from(json['approval'] as Map)
            : null,
      );
    } on Object {
      return null;
    }
  }

  final String tool;
  final String status;
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? error;
  final Map<String, dynamic>? approval;
}

double? _percent(Map<String, dynamic>? json, String key) {
  final part = json?[key];
  final value = part is Map ? part['used_percent'] : part;
  return value is num ? value.toDouble() : null;
}

/// The card for one tool message: a dedicated layout when the result is
/// structured, otherwise the technical details as before.
class ToolCard extends StatelessWidget {
  const ToolCard({
    super.key,
    required this.message,
    required this.pendingIds,
    required this.onOpenApproval,
    this.compact = false,
  });

  final ChatMessage message;

  /// Approvals still pending on the server.
  final Set<String> pendingIds;
  final ValueChanged<String> onOpenApproval;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final payload = ToolPayload.tryParse(message);
    final approvalId = message.approvalRequestId;
    final waiting =
        message.status == 'pending_approval' ||
        payload?.status == 'pending_approval';
    // A request, not its later execution result (which keeps the approval id).
    if (approvalId != null && waiting) {
      return ApprovalCard(
        approvalId: approvalId,
        summary: payload?.approval?['summary'] as String?,
        pending: pendingIds.contains(approvalId),
        compact: compact,
        onOpen: () => onOpenApproval(approvalId),
      );
    }
    if (payload == null) return TechnicalCard(message: message);
    if (payload.status != 'succeeded') {
      return _FailureCard(payload: payload);
    }
    final result = payload.result;
    final disk = _percent(result, 'disk');
    if (payload.tool == 'server_metrics' && disk != null) {
      return DiskCard(
        percent: disk,
        memory: _percent(result, 'memory'),
        cpu: _percent(result, 'cpu_percent'),
        compact: compact,
      );
    }
    if (payload.tool == 'database_status' && result?['available'] is bool) {
      final available = result!['available'] as bool;
      return _SummaryCard(
        icon: Icons.storage_rounded,
        title: 'Base de données',
        value: available ? 'Disponible' : 'Indisponible',
        tone: available ? 'ok' : 'error',
        detail: result['schema_version'] == null
            ? null
            : 'Schéma version ${result['schema_version']}',
      );
    }
    if (payload.tool == 'github_report' && result?['repos'] is List) {
      return _GithubCard(repos: result!['repos'] as List);
    }
    if (payload.tool == 'test_action') {
      return _SummaryCard(
        icon: Icons.science_rounded,
        title: 'Action de démonstration',
        value: 'Exécutée',
        tone: 'ok',
        detail: result?['label'] as String?,
      );
    }
    return TechnicalCard(message: message);
  }
}

/// "Espace disque" with its real value and a gauge (memory and CPU below).
class DiskCard extends StatelessWidget {
  const DiskCard({
    super.key,
    required this.percent,
    this.memory,
    this.cpu,
    this.compact = false,
  });

  final double percent;
  final double? memory;
  final double? cpu;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final others = [
      if (memory != null) 'Mémoire ${formatPercent(memory!)}',
      if (cpu != null) 'Processeur ${formatPercent(cpu!)}',
    ].join(' · ');
    return Semantics(
      label: 'Espace disque utilisé : ${formatPercent(percent)}',
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(compact ? Space.m : Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Row(
                  children: [
                    Icon(
                      Icons.storage_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Space.m),
                    Expanded(
                      child: Text(
                        'Espace disque',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      formatPercent(percent),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.m),
              GaugeBar(percent: percent),
              if (others.isNotEmpty && !compact) ...[
                const SizedBox(height: Space.s),
                Text(
                  others,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A validation request. Amber "Validation requise" only while it is really
/// pending on the server; afterwards a neutral link to its outcome.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approvalId,
    required this.pending,
    required this.onOpen,
    this.summary,
    this.compact = false,
  });

  final String approvalId;
  final bool pending;
  final String? summary;
  final VoidCallback onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NexoraColors.of(context);
    if (!pending) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('Demande de validation traitée'),
          subtitle: summary == null ? null : Text(summary!),
          trailing: TextButton(
            onPressed: onOpen,
            child: const Text('Voir la demande'),
          ),
        ),
      );
    }
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.l),
      side: BorderSide(color: colors.warning.withValues(alpha: 0.7)),
    );
    if (compact) {
      return Card(
        color: colors.warningContainer,
        shape: shape,
        child: InkWell(
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: minTouchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.l,
                vertical: Space.m,
              ),
              child: Semantics(
                button: true,
                label: 'Validation requise. Voir la demande',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Icon(Icons.verified_user_outlined, color: colors.warning),
                    const SizedBox(width: Space.m),
                    Expanded(
                      child: Text(
                        'Validation requise',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.warning,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_forward_rounded, color: colors.warning),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Card(
      color: colors.warningContainer,
      shape: shape,
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.verified_user_outlined, color: colors.warning, size: 30),
            const SizedBox(width: Space.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Validation requise',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onWarningContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    summary ??
                        'Une action sur le serveur nécessite votre validation.',
                    style: TextStyle(color: colors.onWarningContainer),
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Rien n’est exécuté sans votre accord.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onWarningContainer,
                    ),
                  ),
                  const SizedBox(height: Space.m),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.warning,
                      foregroundColor: colors.onWarning,
                    ),
                    onPressed: onOpen,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text('Voir la demande')),
                        SizedBox(width: Space.s),
                        Icon(Icons.arrow_forward_rounded),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.tone,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String value;
  final String tone;
  final String? detail;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: detail == null ? null : Text(detail!),
      trailing: StatusChip(label: value, tone: tone),
    ),
  );
}

class _GithubCard extends StatelessWidget {
  const _GithubCard({required this.repos});

  final List<dynamic> repos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.code_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: Space.m),
                Text('Projets GitHub', style: theme.textTheme.titleMedium),
              ],
            ),
            for (final raw in repos.whereType<Map>()) ...[
              const SizedBox(height: Space.s),
              Text(_repoLine(Map<String, dynamic>.from(raw))),
            ],
          ],
        ),
      ),
    );
  }

  static String _repoLine(Map<String, dynamic> repo) {
    final name = repo['repo'] ?? 'Dépôt';
    if (repo['available'] == false) {
      return '$name : ${repo['error'] ?? 'indisponible'}';
    }
    final runs = repo['workflow_runs'];
    final last = runs is List && runs.isNotEmpty && runs.first is Map
        ? (runs.first as Map)['conclusion']
        : null;
    final ci = switch (last) {
      'success' => 'CI réussie',
      'failure' => 'CI en échec',
      null => 'CI sans résultat',
      _ => 'CI : $last',
    };
    final issues = repo['open_issues'];
    return '$name · $ci${issues is num ? ' · $issues ticket(s) ouvert(s)' : ''}';
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.payload});

  final ToolPayload payload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = payload.error;
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        textColor: scheme.onErrorContainer,
        iconColor: scheme.onErrorContainer,
        leading: const Icon(Icons.error_outline_rounded),
        title: Text(
          '${toolLabel(payload.tool)} : '
          '${executionStatusLabels[payload.status] ?? payload.status}',
        ),
        subtitle: error == null
            ? null
            : Text('${error['message'] ?? error['code']}'),
      ),
    );
  }
}

/// Raw details, for results without a dedicated card and older messages.
class TechnicalCard extends StatelessWidget {
  const TechnicalCard({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final payload = ToolPayload.tryParse(message);
    Object? details;
    try {
      details = jsonDecode(message.content);
    } on Object {
      details = message.content;
    }
    final status = payload?.status ?? message.status;
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        leading: const Icon(Icons.build_circle_rounded),
        title: Text(toolLabel(payload?.tool ?? 'outil')),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: Space.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: StatusChip(
              label: executionStatusLabels[status] ?? status,
              tone: statusTones[status] ?? 'neutral',
            ),
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          Space.l,
          0,
          Space.l,
          Space.m,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            details is String
                ? details
                : const JsonEncoder.withIndent('  ').convert(details),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          Text(
            formatShort(message.createdAt),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
