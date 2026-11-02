import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';
import 'approval_detail_screen.dart';

class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  bool _pendingOnly = true;
  List<Approval>? _items;
  ApiError? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      final items = await state.api.approvals(
        status: _pendingOnly ? 'pending' : null,
      );
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error);
    }
    await state.refreshPending();
  }

  Future<void> _open(Approval approval) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApprovalDetailScreen(approvalId: approval.id),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (_error != null && items == null) {
      body = ErrorView(error: _error!, onRetry: _load);
    } else if (items == null) {
      body = const LoadingView(label: 'Chargement des validations…');
    } else if (items.isEmpty) {
      body = MessageView(
        icon: Icons.task_alt,
        title: _pendingOnly
            ? 'Aucune validation en attente'
            : 'Aucune validation',
        body: 'Les actions sensibles demandées par NEXORA apparaîtront ici.',
      );
    } else {
      body = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) =>
            _ApprovalCard(approval: items[index], onTap: _open),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Validations'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('En attente'),
                  icon: Icon(Icons.pending_actions),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Toutes'),
                  icon: Icon(Icons.history),
                ),
              ],
              selected: {_pendingOnly},
              onSelectionChanged: (selection) {
                setState(() {
                  _pendingOnly = selection.first;
                  _items = null;
                });
                _load();
              },
            ),
          ),
          if (_error != null && items != null)
            NoticeBar(tone: 'error', message: _error!.message),
          Expanded(
            child: RefreshIndicator(onRefresh: _load, child: body),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.approval, required this.onTap});

  final Approval approval;
  final ValueChanged<Approval> onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onTap(approval),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    toolLabel(approval.tool),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                StatusChip(
                  label:
                      approvalStatusLabels[approval.status] ?? approval.status,
                  tone: statusTones[approval.status] ?? 'neutral',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(approval.summary),
            const SizedBox(height: 8),
            Text(
              '${riskLabels[approval.risk] ?? approval.risk} · '
              '${approval.status == 'pending' || approval.status == 'approved' ? 'expire ${formatShort(approval.expiresAt)}' : 'demandée ${formatShort(approval.createdAt)}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}
