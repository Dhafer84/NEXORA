import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'src/alerts/background_alerts.dart';
import 'src/bubble/bubble_service.dart';
import 'src/files/file_access.dart';
import 'src/files/folder_memory.dart';
import 'src/health/health_service.dart';
import 'src/session/session.dart';
import 'src/state/app_state.dart';
import 'src/storage/credentials_store.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/mini_chat.dart';
import 'src/ui/theme.dart';
import 'src/voice/voice_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  final state = AppState(
    store: SecureCredentialsStore(),
    alerts: await WorkManagerAlerts.initialize(),
    files: const ChannelFileAccess(),
    folderMemory: PreferencesFolderMemory(),
    voice: NativeVoiceService(),
    bubble: NativeBubbleService(),
    health: NativeHealthService(),
    turns: NativeTurnLock(),
    session: PreferencesSessionStore(),
    timezone: () async => (await FlutterTimezone.getLocalTimezone()).identifier,
  );
  WidgetsBinding.instance.addObserver(state);
  runApp(NexoraApp(state: state));
  await state.load();
}

/// Entry point of the Android bubble (`BubbleActivity`): a second Flutter
/// engine in the same process, sharing the key store, drafts and turn lock.
@pragma('vm:entry-point')
Future<void> bubbleMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  final state = AppState(
    store: SecureCredentialsStore(),
    voice: NativeVoiceService(),
    bubble: NativeBubbleService(),
    turns: NativeTurnLock(),
    session: PreferencesSessionStore(),
    window: 'bubble',
  );
  WidgetsBinding.instance.addObserver(state);
  runApp(NexoraApp(state: state, home: const MiniChat()));
  await state.load();
}

class NexoraApp extends StatelessWidget {
  const NexoraApp({
    super.key,
    required this.state,
    this.themeMode = ThemeMode.system,
    this.home = const HomeShell(),
  });

  final AppState state;

  /// Follows the phone setting; fixed only by tests and screenshots.
  final ThemeMode themeMode;
  final Widget home;

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: MaterialApp(
      title: 'NEXORA',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      locale: const Locale('fr', 'FR'),
      supportedLocales: const [Locale('fr', 'FR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home,
    ),
  );
}
