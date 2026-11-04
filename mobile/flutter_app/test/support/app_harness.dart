import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora/main.dart';
import 'package:nexora/src/activity/activity_store.dart';
import 'package:nexora/src/alerts/background_alerts.dart';
import 'package:nexora/src/bubble/bubble_service.dart';
import 'package:nexora/src/files/file_access.dart';
import 'package:nexora/src/health/health_service.dart';
import 'package:nexora/src/session/session.dart';
import 'package:nexora/src/state/app_state.dart';
import 'package:nexora/src/storage/credentials_store.dart';
import 'package:nexora/src/voice/voice_service.dart';

import 'fake_backend.dart';

final List<AppState> _started = [];

/// Like [testWidgets], but stops the app state (and its polling timer) before
/// the framework checks that no timer is left behind.
void testApp(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    // Phone-sized portrait view unless the test sets its own.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      for (final state in _started) {
        state.dispose();
      }
      _started.clear();
    }
  });
}

/// Starts the real application widget against [backend], optionally already configured.
Future<AppState> pumpApp(
  WidgetTester tester,
  FakeBackend backend, {
  bool configured = true,
  ThemeMode themeMode = ThemeMode.light,
  AlertsController? alerts,
  FileAccess? files,
  FolderMemory? folderMemory,
  VoiceService? voice,
  BubbleService? bubble,
  HealthService? health,
  ActivityStore? activityStore,
  TurnLock? turns,
  SessionStore? session,
}) async {
  final state = await startState(
    backend,
    configured: configured,
    alerts: alerts ?? FakeAlerts(),
    files: files,
    folderMemory: folderMemory,
    voice: voice,
    bubble: bubble,
    health: health,
    activityStore: activityStore,
    turns: turns,
    session: session,
  );
  await tester.pumpWidget(NexoraApp(state: state, themeMode: themeMode));
  await state.load();
  await tester.pumpAndSettle();
  return state;
}

/// An application state against [backend], disposed at the end of the test.
/// Several states sharing [turns] and [session] stand for the two NEXORA
/// windows (full app and bubble).
Future<AppState> startState(
  FakeBackend backend, {
  bool configured = true,
  AlertsController? alerts,
  FileAccess? files,
  FolderMemory? folderMemory,
  VoiceService? voice,
  BubbleService? bubble,
  HealthService? health,
  ActivityStore? activityStore,
  TurnLock? turns,
  SessionStore? session,
  String window = 'app',
}) async {
  await initializeDateFormatting('fr_FR');
  FlutterSecureStorage.setMockInitialValues(
    configured
        ? {
            SecureCredentialsStore.entryKey: jsonEncode({
              'base_url': testBaseUrl,
              'api_key': backend.apiKey,
            }),
          }
        : {},
  );
  final state = AppState(
    store: SecureCredentialsStore(),
    apiFactory: backend.factory,
    alerts: alerts,
    files: files,
    folderMemory: folderMemory,
    voice: voice,
    bubble: bubble,
    health: health,
    activityStore:
        activityStore ?? (health == null ? null : MemoryActivityStore()),
    turns: turns,
    session: session,
    window: window,
    timezone: () async => 'Europe/Paris',
  );
  _started.add(state);
  return state;
}

/// Phone alerts without Android: records what the app asked for.
class FakeAlerts implements AlertsController {
  FakeAlerts({this.permitted = true});

  /// What Android answers to the notification permission request.
  bool permitted;
  bool enabled = false;
  int enableCalls = 0;

  @override
  Future<AlertsStatus> status() async =>
      AlertsStatus(enabled: enabled, permitted: permitted);

  @override
  Future<String?> enable() async {
    enableCalls++;
    if (!permitted) return 'Notifications refusées par Android.';
    enabled = true;
    return null;
  }

  @override
  Future<void> disable() async => enabled = false;
}
