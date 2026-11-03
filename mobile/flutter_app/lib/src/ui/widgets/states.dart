import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../theme.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = 'Chargement…'});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(label),
        ],
      ),
    ),
  );
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final ApiError error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => MessageView(
    icon: error.kind == ApiErrorKind.forbidden
        ? Icons.lock_outline_rounded
        : Icons.cloud_off_rounded,
    title: error.kind == ApiErrorKind.forbidden
        ? 'Accès refusé'
        : 'Impossible de charger',
    body: error.message,
    action: onRetry == null
        ? null
        : FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Réessayer'),
          ),
  );
}

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.tone = 'neutral',
    this.icon,
  });

  final String label;
  final String tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(Theme.of(context).colorScheme, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: colors.foreground),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: colors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class NoticeBar extends StatelessWidget {
  const NoticeBar({
    super.key,
    required this.tone,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.onClose,
  });

  final String tone;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = toneColors(Theme.of(context).colorScheme, tone);
    return Material(
      color: colors.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Icon(
              tone == 'error'
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              color: colors.foreground,
            ),
            const SizedBox(width: 12),
            // The action sits under the text: long messages and large text
            // never squeeze it into a narrow column.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message, style: TextStyle(color: colors.foreground)),
                  if (actionLabel != null)
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
            ),
            if (onClose != null)
              IconButton(
                tooltip: 'Fermer le message',
                onPressed: onClose,
                icon: Icon(Icons.close_rounded, color: colors.foreground),
              ),
          ],
        ),
      ),
    );
  }
}

const statusTones = {
  'pending': 'warning',
  'approved': 'warning',
  'rejected': 'error',
  'expired': 'neutral',
  'consumed': 'ok',
  'succeeded': 'ok',
  'pending_approval': 'warning',
  'denied': 'error',
  'invalid': 'error',
  'failed': 'error',
  'timed_out': 'error',
};

/// Rounded usage bar of the chat cards and the dashboard (0–100 %).
class GaugeBar extends StatelessWidget {
  const GaugeBar({super.key, required this.percent, this.height = 10});

  final double percent;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = NexoraColors.of(context);
    final color = percent >= 90
        ? scheme.error
        : percent >= 80
        ? colors.warning
        : scheme.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: LinearProgressIndicator(
        value: (percent / 100).clamp(0, 1),
        minHeight: height,
        color: color,
        backgroundColor: colors.gaugeTrack,
      ),
    );
  }
}
