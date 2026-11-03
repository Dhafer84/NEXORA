import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';
import 'chat_screen.dart';

/// One validation request. Status always comes from the server, never from the
/// phone clock. Approving and executing are two distinct, explicit user actions.
class ApprovalDetailScreen extends StatefulWidget {
  const ApprovalDetailScreen({super.key, required this.approvalId});

  final String approvalId;

  @override
  State<ApprovalDetailScreen> createState() => _ApprovalDetailScreenState();
}

class _ApprovalDetailScreenState extends State<ApprovalDetailScreen> {
  Approval? _approval;
  ApiError? _error;
  ToolExecution? _execution;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final approval = await AppScope.read(
        context,
      ).api.approval(widget.approvalId);
      if (mounted) {
        setState(() {
          _approval = approval;
          _error = null;
        });
      }
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  /// Runs one server call, then always reloads the authoritative status.
  Future<void> _run(Future<void> Function(AppState state) call) async {
    if (_busy) return;
    final state = AppScope.read(context);
    setState(() => _busy = true);
    try {
      await call(state);
    } on ApiError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_explain(error))));
      }
    } finally {
      await _load();
      await state.refreshPending();
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _explain(ApiError error) => switch (error.code) {
    'approval_expired' =>
      'Cette demande a expiré : une nouvelle demande est nécessaire.',
    'approval_rejected' =>
      'Cette demande a été refusée : elle ne peut plus être exécutée.',
    'approval_pending' => 'La demande doit d’abord être approuvée.',
    'approval_arguments_mismatch' =>
      'Les paramètres ne correspondent plus à ceux approuvés : nouvelle validation requise.',
    _ when error.outcomeUnknown =>
      '${error.message} Statut rechargé depuis le serveur ; une nouvelle tentative ne '
          'réexécute pas une action déjà faite.',
    _ => error.message,
  };

  Future<void> _approve(Approval approval) async {
    final ok = await _confirm(
      'Approuver cette action ?',
      '${approval.summary}\n\nParamètres exacts :\n${_pretty(approval.arguments)}\n\n'
          'L’approbation n’exécute pas encore l’action : vous pourrez ensuite '
          'la lancer explicitement.',
      'Approuver',
    );
    if (ok) await _run((state) => state.api.approve(approval));
  }

  Future<void> _reject(Approval approval) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (reason != null) {
      await _run((state) => state.api.reject(approval.id, reason: reason));
    }
  }

  Future<void> _execute(Approval approval) async {
    final ok = await _confirm(
      'Exécuter maintenant ?',
      '${approval.summary}\n\nL’action sera exécutée une seule fois sur le serveur, '
          'avec les paramètres approuvés.',
      'Exécuter',
    );
    if (ok) {
      await _run((state) async {
        final execution = await state.api.execute(approval);
        if (mounted) setState(() => _execution = execution);
      });
    }
  }

  Future<void> _showStored(Approval approval) => _run((state) async {
    // Replays the stored outcome; the server never runs a consumed action again.
    final execution = await state.api.execute(approval);
    if (mounted) setState(() => _execution = execution);
  });

  Future<void> _openConversation(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ChatScreen(conversationId: id)),
  );

  @override
  Widget build(BuildContext context) {
    final approval = _approval;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Validation'),
        actions: [
          IconButton(
            tooltip: 'Actualiser le statut',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: approval == null
          ? (_error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : const LoadingView())
          : SafeArea(child: _content(context, approval)),
    );
  }

  Widget _content(BuildContext context, Approval approval) {
    final theme = Theme.of(context);
    final execution = _execution;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        Text(toolLabel(approval.tool), style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StatusChip(
              label: approvalStatusLabels[approval.status] ?? approval.status,
              tone: statusTones[approval.status] ?? 'neutral',
            ),
            StatusChip(
              label: riskLabels[approval.risk] ?? approval.risk,
              tone: approval.risk == 'low'
                  ? 'neutral'
                  : approval.risk == 'high'
                  ? 'error'
                  : 'warning',
              icon: Icons.shield_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(approval.summary, style: theme.textTheme.titleMedium),
        const SizedBox(height: 16),
        _Field(label: 'Outil', value: approval.tool),
        _Field(label: 'Demandée', value: formatDateTime(approval.createdAt)),
        _Field(
          label: 'Expiration',
          value:
              '${formatDateTime(approval.expiresAt)} (statut vérifié par le serveur)',
        ),
        if (approval.decidedAt != null)
          _Field(label: 'Décision', value: formatDateTime(approval.decidedAt!)),
        if (approval.decisionReason != null)
          _Field(label: 'Motif', value: approval.decisionReason!),
        if (approval.consumedAt != null)
          _Field(
            label: 'Exécutée',
            value: formatDateTime(approval.consumedAt!),
          ),
        const SizedBox(height: 8),
        Text('Paramètres exacts', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _pretty(approval.arguments),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 8),
        _Field(label: 'Empreinte', value: approval.argumentsHash, mono: true),
        const SizedBox(height: 16),
        ..._actions(approval),
        if (execution != null) ...[
          const SizedBox(height: 24),
          _ExecutionCard(execution: execution),
        ],
        if (approval.conversationId != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _openConversation(approval.conversationId!),
            icon: const Icon(Icons.forum_rounded),
            label: const Text('Ouvrir la conversation'),
          ),
        ],
      ],
    );
  }

  List<Widget> _actions(Approval approval) {
    final disabled = _busy;
    switch (approval.status) {
      case 'pending':
        return [
          const _Note(
            'Rien n’est exécuté sans votre accord. Approuver puis exécuter sont deux étapes.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: disabled ? null : () => _approve(approval),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Approuver'),
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : () => _reject(approval),
                icon: const Icon(Icons.block_rounded),
                label: const Text('Refuser'),
              ),
            ],
          ),
        ];
      case 'approved':
        return [
          const _Note(
            'Approuvée mais pas encore exécutée. Vous pouvez l’exécuter ou la révoquer.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: disabled ? null : () => _execute(approval),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Exécuter maintenant'),
              ),
              OutlinedButton.icon(
                onPressed: disabled ? null : () => _reject(approval),
                icon: const Icon(Icons.block_rounded),
                label: const Text('Révoquer'),
              ),
            ],
          ),
        ];
      case 'consumed':
        return [
          const _Note('Action déjà exécutée. Elle ne peut pas être relancée.'),
          if (_execution == null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: disabled ? null : () => _showStored(approval),
                icon: const Icon(Icons.receipt_long_rounded),
                label: const Text('Afficher le résultat enregistré'),
              ),
            ),
        ];
      case 'rejected':
        return const [_Note('Refusée : cette action ne sera pas exécutée.')];
      case 'expired':
        return const [
          _Note(
            'Expirée : non exécutée. Redemandez l’action pour obtenir une nouvelle validation.',
          ),
        ];
      default:
        return const [];
    }
  }
}

String _pretty(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        SelectableText(
          value,
          style: mono
              ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
              : null,
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.info_outline_rounded, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(text)),
    ],
  );
}

class _ExecutionCard extends StatelessWidget {
  const _ExecutionCard({required this.execution});

  final ToolExecution execution;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Résultat', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              Flexible(
                child: StatusChip(
                  label:
                      executionStatusLabels[execution.status] ??
                      execution.status,
                  tone: statusTones[execution.status] ?? 'neutral',
                ),
              ),
            ],
          ),
          if (execution.replayed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Résultat enregistré : aucune nouvelle exécution n’a eu lieu.',
              ),
            ),
          if (execution.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(execution.errorMessage!),
            ),
          if (execution.result != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              _pretty(execution.result),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ],
          if (execution.approval?.conversationId != null && !execution.replayed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Le résultat a été ajouté à la conversation.'),
            ),
        ],
      ),
    ),
  );
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Refuser cette action ?'),
    content: TextField(
      controller: _controller,
      maxLength: 500,
      decoration: const InputDecoration(labelText: 'Motif (facultatif)'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Refuser'),
      ),
    ],
  );
}
