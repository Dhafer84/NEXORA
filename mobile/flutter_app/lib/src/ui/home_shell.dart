import 'dart:async';

import 'package:flutter/material.dart';

import '../bubble/bubble_service.dart';
import '../state/app_state.dart';
import 'activity/activity_screen.dart';
import 'screens/approval_detail_screen.dart';
import 'screens/automations_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/messages_screen.dart';
import 'screens/settings_screen.dart';

/// Root of the configured application, or the first-run settings screen.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _messages = 0;
  int _index = _messages;

  /// Réglages is the last tab; Activité comes before it where Health
  /// Connect is supported.
  int get _settings => AppScope.read(context).health == null ? 3 : 4;
  StreamSubscription<LaunchRequest>? _launches;

  @override
  void initState() {
    super.initState();
    _launches = AppScope.read(context).bubble?.launches.listen(_launch);
  }

  @override
  void dispose() {
    _launches?.cancel();
    super.dispose();
  }

  /// A shortcut or the mini-chat asked for a conversation or an approval.
  Future<void> _launch(LaunchRequest request) async {
    final state = AppScope.read(context);
    if (state.setup != SetupState.ready) return;
    final conversation = request.conversationId;
    if (conversation != null) await state.setCurrentConversation(conversation);
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _index = _messages);
    final approval = request.approvalId;
    if (approval != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ApprovalDetailScreen(approvalId: approval),
        ),
      );
      await state.refreshPending();
    }
  }

  Future<void> _openBubble(String conversationId) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final problem = await state.bubble!.show(
      conversationId: conversationId,
      title: 'NEXORA',
      expand: true,
    );
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    switch (state.setup) {
      case SetupState.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SetupState.unconfigured:
        return const SettingsScreen(firstRun: true);
      case SetupState.ready:
        break;
    }
    // Screens are rebuilt per tab so each one reloads fresh server data when shown.
    final screens = [
      MessagesScreen(
        onVoiceSettings: () => setState(() => _index = _settings),
        onOpenBubble: state.bubble == null ? null : _openBubble,
      ),
      const DashboardScreen(),
      const AutomationsScreen(),
      if (state.health != null) const ActivityScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.chat_outlined),
            selectedIcon: Icon(Icons.chat_rounded),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns_rounded),
            label: 'Serveur',
          ),
          const NavigationDestination(
            icon: Icon(Icons.check_box_outlined),
            selectedIcon: Icon(Icons.check_box_rounded),
            label: 'Tâches',
          ),
          if (state.health != null)
            const NavigationDestination(
              icon: Icon(Icons.directions_walk_outlined),
              selectedIcon: Icon(Icons.directions_walk_rounded),
              label: 'Activité',
            ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Réglages',
          ),
        ],
      ),
    );
  }
}
