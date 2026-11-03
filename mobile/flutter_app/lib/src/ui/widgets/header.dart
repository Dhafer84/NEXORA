import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../screens/approvals_screen.dart';
import '../theme.dart';

/// Server reachability dot and label ("Connecté") for the headers.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final colors = NexoraColors.of(context);
    final (label, color) = switch (state.connection) {
      ConnectionStatus.connected => ('Connecté', colors.success),
      ConnectionStatus.keyRefused => ('Clé refusée', scheme.error),
      ConnectionStatus.unreachable => ('Hors ligne', scheme.error),
      ConnectionStatus.checking => ('Connexion…', scheme.onSurfaceVariant),
    };
    return Semantics(
      label: 'État du serveur : $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.s),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Global access to validation requests, with the pending count.
class ValidationsButton extends StatelessWidget {
  const ValidationsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pending = state.pendingApprovals ?? 0;
    final colors = NexoraColors.of(context);
    return IconButton(
      tooltip: pending > 0
          ? 'Validations : $pending en attente'
          : 'Validations',
      onPressed: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ApprovalsScreen()),
        );
        await state.refreshPending();
      },
      icon: Badge(
        isLabelVisible: pending > 0,
        label: Text('$pending'),
        child: Icon(
          pending > 0
              ? Icons.verified_user_rounded
              : Icons.verified_user_outlined,
          color: pending > 0 ? colors.warning : null,
        ),
      ),
    );
  }
}

/// Header actions shared by the main tabs.
List<Widget> headerActions({List<Widget> extra = const []}) => [
  ...extra,
  const ValidationsButton(),
];
