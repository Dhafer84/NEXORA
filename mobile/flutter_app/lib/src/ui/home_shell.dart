import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'screens/approvals_screen.dart';
import 'screens/conversations_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/settings_screen.dart';

/// Root of the configured application, or the first-run settings screen.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

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
    final pending = state.pendingApprovals ?? 0;
    // Screens are rebuilt per tab so each one reloads fresh server data when shown.
    final screens = [
      const ConversationsScreen(),
      const DashboardScreen(),
      const ApprovalsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: 'Serveur',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.fact_check_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.fact_check),
            ),
            label: 'Validations',
            tooltip: pending > 0
                ? '$pending validation(s) en attente'
                : 'Validations',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Réglages',
          ),
        ],
      ),
    );
  }
}
