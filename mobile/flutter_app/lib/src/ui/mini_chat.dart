import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'chat/chat_panel.dart';
import 'theme.dart';
import 'widgets/states.dart';

/// Content of the Android bubble: the chosen conversation in a compact
/// window, with full-screen and reduce buttons. Same server, same key and
/// same history as the full app.
class MiniChat extends StatefulWidget {
  const MiniChat({super.key});

  @override
  State<MiniChat> createState() => _MiniChatState();
}

class _MiniChatState extends State<MiniChat> {
  String? _conversationId;
  bool _loaded = false;
  final _panel = GlobalKey<ChatPanelState>();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    final id =
        await state.bubble?.bubbleConversation() ??
        await state.currentConversation();
    if (mounted) {
      setState(() {
        _conversationId = id;
        _loaded = true;
      });
    }
  }

  Future<void> _fullScreen({String? approvalId}) async {
    final state = AppScope.read(context);
    final id = _conversationId;
    // The draft goes with the conversation: the full app restores it.
    await _panel.currentState?.saveDraft();
    if (id != null) await state.setCurrentConversation(id);
    await state.bubble?.openFullScreen(
      conversationId: id ?? '',
      approvalId: approvalId,
    );
    // Android collapses the bubble when another app was in front. When the
    // full app already was, the bubble stays open over it: say so.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Ouvert dans l’application NEXORA, derrière la bulle : touchez '
          'l’icône de la bulle pour la réduire.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final id = _conversationId;
    Widget body;
    if (state.setup == SetupState.loading || !_loaded) {
      body = const LoadingView();
    } else if (state.setup == SetupState.unconfigured) {
      body = MessageView(
        icon: Icons.key_rounded,
        title: 'NEXORA n’est pas configuré',
        body: 'Saisissez l’adresse et la clé dans l’application.',
        action: FilledButton(
          onPressed: _fullScreen,
          child: const Text('Ouvrir NEXORA'),
        ),
      );
    } else if (id == null) {
      body = MessageView(
        icon: Icons.chat_rounded,
        title: 'Aucune discussion choisie',
        action: FilledButton(
          onPressed: _fullScreen,
          child: const Text('Ouvrir NEXORA'),
        ),
      );
    } else {
      body = ChatPanel(
        key: _panel,
        conversationId: id,
        compact: true,
        // Validation happens in the full app's existing screen, never here.
        onOpenApproval: (approval) => _fullScreen(approvalId: approval),
        onVoiceSettings: _fullScreen,
      );
    }
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainer,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.l,
                Space.xs,
                Space.xs,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('NEXORA', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: 'Agrandir en plein écran',
                    onPressed: _fullScreen,
                    icon: const Icon(Icons.open_in_full_rounded),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
