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
        ? Icons.lock_outline
        : Icons.cloud_off_outlined,
    title: error.kind == ApiErrorKind.forbidden
        ? 'Accès refusé'
        : 'Impossible de charger',
    body: error.message,
    action: onRetry == null
        ? null
        : FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
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
              tone == 'error' ? Icons.error_outline : Icons.info_outline,
              color: colors.foreground,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: colors.foreground)),
            ),
            if (actionLabel != null)
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            if (onClose != null)
              IconButton(
                tooltip: 'Fermer le message',
                onPressed: onClose,
                icon: Icon(Icons.close, color: colors.foreground),
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
