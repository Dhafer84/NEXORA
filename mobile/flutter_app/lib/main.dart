import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'src/alerts/background_alerts.dart';
import 'src/files/file_access.dart';
import 'src/files/folder_memory.dart';
import 'src/state/app_state.dart';
import 'src/storage/credentials_store.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  final state = AppState(
    store: SecureCredentialsStore(),
    alerts: await WorkManagerAlerts.initialize(),
    files: const ChannelFileAccess(),
    folderMemory: PreferencesFolderMemory(),
    timezone: () async => (await FlutterTimezone.getLocalTimezone()).identifier,
  );
  WidgetsBinding.instance.addObserver(state);
  runApp(NexoraApp(state: state));
  await state.load();
}

class NexoraApp extends StatelessWidget {
  const NexoraApp({
    super.key,
    required this.state,
    this.themeMode = ThemeMode.system,
  });

  final AppState state;

  /// Follows the phone setting; fixed only by tests and screenshots.
  final ThemeMode themeMode;

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
      home: const HomeShell(),
    ),
  );
}
